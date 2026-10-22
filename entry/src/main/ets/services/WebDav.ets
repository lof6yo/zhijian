import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util, url } from '@kit.ArkTS';

const DOMAIN = 0x0000;
const TAG = 'ZhijianDav';

/** One entry returned by PROPFIND. */
export class DavEntry {
  /** Path relative to the configured base, e.g. `notes/a.md`. */
  relPath: string = '';
  isDir: boolean = false;
  /** Bytes; -1 when the server did not report it (collections). */
  size: number = -1;
  /** Epoch ms from `getlastmodified`; 0 when absent. */
  modifiedAt: number = 0;
  etag: string = '';
}

export class DavResult {
  ok: boolean = false;
  status: number = 0;
  message: string = '';
}

/** What a `PROPFIND` call produced. */
export class DavListResult extends DavResult {
  entries: DavEntry[] = [];
}

export class DavConfig {
  /** Trailing-slash-normalised base URL, e.g. `https://host/dav/`. */
  baseUrl: string = '';
  username: string = '';
  password: string = '';
  /**
   * Optional hostname → IP pin, for networks whose resolver cannot answer.
   *
   * This does *not* weaken TLS: SNI and certificate validation still use the
   * hostname in `baseUrl`, so a wrong or expired certificate is still rejected.
   * It only replaces the name lookup step. It exists because some environments
   * (NAS on a LAN with no internal DNS, and the HarmonyOS emulator, whose
   * `/etc/resolv.conf` points at unreachable servers and which refuses `root`
   * so the file cannot be fixed) can reach the server by IP but cannot resolve
   * its name.
   */
  dnsHost: string = '';
  dnsIp: string = '';
  /**
   * HTTP proxy the request must tunnel through; empty = follow the system.
   *
   * Corporate networks frequently expose no direct egress and force every
   * HTTPS connection through an authenticating CONNECT proxy. `rcp` defaults to
   * `proxy: 'system'`, which reads the *device's* proxy setting — and a device
   * that has none configured will simply time out on a network that requires
   * one. An explicit value overrides that.
   */
  proxyUrl: string = '';
}

/**
 * Minimal WebDAV client over RCP.
 *
 * Why RCP and not `@ohos.net.http`: `http.RequestMethod` is a closed enum
 * (GET/HEAD/POST/PUT/DELETE/TRACE/CONNECT/PATCH/OPTIONS) with no `PROPFIND` or
 * `MKCOL`, and no escape hatch. `rcp.HttpMethod` is
 * `'GET' | ... | (string & NonNullable<unknown>)`, so arbitrary verbs are legal,
 * and `rcp.SecurityConfiguration.serverAuthentication` does RFC 7617 basic auth
 * natively — no manual base64 header, no pre-flight 401 dance.
 *
 * The client is deliberately stateless: one `Session` per call, closed in a
 * `finally`. WebDAV requests here are user-initiated and rare, so session reuse
 * would buy nothing and would leak connections on failure paths.
 */
export class WebDavClient {
  private static session(config: DavConfig): rcp.Session {
    const security: rcp.SecurityConfiguration = {
      serverAuthentication: {
        credential: { username: config.username, password: config.password },
        authenticationType: 'basic'
      }
    };
    const conf: rcp.SessionConfiguration = {
      baseAddress: config.baseUrl,
      headers: { 'user-agent': 'Zhijian/1.0' },
      requestConfiguration: { security }
    };
    if (config.dnsHost.length > 0 && config.dnsIp.length > 0) {
      // A static rule is keyed on host:port, so it must match the port the URL
      // actually uses, not a hardcoded 443. It belongs on the request
      // `Configuration` (`dns`), not on `SessionConfiguration`.
      const rule: rcp.StaticDnsRule = {
        host: config.dnsHost,
        port: WebDavClient.portOf(config.baseUrl),
        ipAddresses: [config.dnsIp]
      };
      const dns: rcp.DnsConfiguration = { dnsRules: [rule] };
      conf.requestConfiguration = { security, dns };
    }
    if (config.proxyUrl.length > 0) {
      // `createTunnel: 'always'` is required for HTTPS: the proxy must accept a
      // CONNECT and carry raw TLS, otherwise the request would be sent to the
      // proxy as a plain absolute-URI GET and the TLS handshake would never
      // happen.
      const proxy: rcp.WebProxy = {
        url: config.proxyUrl,
        createTunnel: 'always'
      };
      const base: rcp.Configuration = conf.requestConfiguration ?? {};
      base.proxy = proxy;
      conf.requestConfiguration = base;
    }
    return rcp.createSession(conf);
  }

  private static portOf(baseUrl: string): number {
    try {
      const parsed = new url.URL(baseUrl);
      if (parsed.port.length > 0) {
        return parseInt(parsed.port, 10);
      }
      return parsed.protocol === 'http:' ? 80 : 443;
    } catch (error) {
      return 443;
    }
  }

  /**
   * One request, on its own session, retried on a transient transport failure.
   *
   * The retry is not defensive padding. Behind an HTTP CONNECT proxy a fresh
   * tunnel occasionally dies during setup and RCP surfaces it as
   * `500 Connection established` — the proxy's own status line for the tunnel,
   * not the server's answer to the request. `curl` against the same URL and
   * proxy succeeds on every attempt, and the next sync succeeds too, so the
   * request never reached the origin at all. Without a retry a single lost
   * tunnel aborts the whole run (a partial listing cannot be merged safely),
   * which on a real network means "sync often just fails".
   *
   * Every verb used here is idempotent for the same body — `PUT` rewrites
   * identical bytes, `PROPFIND`/`GET`/`DELETE` are safe to repeat — so a
   * request that actually landed before the tunnel collapsed is retried
   * harmlessly.
   */
  private static async send(config: DavConfig, method: string, relPath: string,
    body: string | undefined, extraHeaders: rcp.RequestHeaders | undefined): Promise<rcp.Response> {
    const attempts = 3;
    let last: Error | undefined = undefined;
    for (let attempt = 0; attempt < attempts; attempt++) {
      const session = WebDavClient.session(config);
      try {
        const headers: rcp.RequestHeaders = {};
        if (extraHeaders !== undefined) {
          const keys = Object.keys(extraHeaders);
          for (let i = 0; i < keys.length; i++) {
            headers[keys[i]] = extraHeaders[keys[i]];
          }
        }
        const content: string | undefined = body;
        const request = new rcp.Request(relPath, method, headers, content);
        request.configuration = { transfer: { timeout: { connectMs: 10000, transferMs: 30000 } } };
        const response = await session.fetch(request);
        if (response.statusCode >= 500 && response.statusCode !== 501 && attempt + 1 < attempts) {
          hilog.warn(DOMAIN, TAG, '%{public}s %{public}s -> %{public}d, retrying',
            method, relPath, response.statusCode);
          continue;
        }
        return response;
      } catch (error) {
        last = error as Error;
        hilog.warn(DOMAIN, TAG, '%{public}s %{public}s threw (%{public}d/%{public}d): %{public}s',
          method, relPath, attempt + 1, attempts, WebDavClient.describe(error));
        if (attempt + 1 >= attempts) {
          throw last;
        }
      } finally {
        session.close();
      }
    }
    throw last ?? new Error('request failed');
  }

  /** `PROPFIND` at `Depth: 1`; the collection itself is filtered out. */
  static async list(config: DavConfig, relPath: string): Promise<DavListResult> {
    const result = new DavListResult();
    const body = '<?xml version="1.0" encoding="utf-8"?>' +
      '<D:propfind xmlns:D="DAV:"><D:prop>' +
      '<D:displayname/><D:getcontentlength/><D:getlastmodified/>' +
      '<D:resourcetype/><D:getetag/>' +
      '</D:prop></D:propfind>';
    try {
      const response = await WebDavClient.send(config, 'PROPFIND', relPath, body, {
        'depth': '1',
        'content-type': 'application/xml; charset=utf-8'
      });
      result.status = response.statusCode;
      if (response.statusCode !== 207) {
        result.message = `PROPFIND ${response.statusCode} ${response.reasonPhrase ?? ''}`.trim();
        return result;
      }
      const text = WebDavClient.decode(response.body);
      result.entries = DavXml.parseMultiStatus(text, config.baseUrl, relPath);
      result.ok = true;
      return result;
    } catch (error) {
      result.message = WebDavClient.describe(error);
      hilog.error(DOMAIN, TAG, 'list failed: %{public}s', result.message);
      return result;
    }
  }

  /** `MKCOL`. A 405 means "already there", which callers treat as success. */
  static async makeCollection(config: DavConfig, relPath: string): Promise<DavResult> {
    return WebDavClient.simple(config, 'MKCOL', relPath, undefined);
  }

  /** `PUT` with an explicit `application/octet-stream` body. */
  static async put(config: DavConfig, relPath: string, content: string,
    expectedAbsent: boolean = false): Promise<DavResult> {
    const result = new DavResult();
    try {
      const headers: rcp.RequestHeaders = { 'content-type': 'text/markdown; charset=utf-8' };
      if (expectedAbsent) {
        headers['if-none-match'] = '*';
      }
      const response = await WebDavClient.send(config, 'PUT', relPath, content, headers);
      result.status = response.statusCode;
      // 201 created, 204 overwritten. 412 is our own `If-None-Match: *` guard.
      result.ok = response.statusCode === 201 || response.statusCode === 204 ||
        response.statusCode === 200;
      if (!result.ok) {
        result.message = `PUT ${response.statusCode} ${response.reasonPhrase ?? ''}`.trim();
      }
      return result;
    } catch (error) {
      result.message = WebDavClient.describe(error);
      return result;
    }
  }

  /** `GET`. Returns the body text; `ok` is false for a non-2xx status. */
  static async get(config: DavConfig, relPath: string): Promise<DavResult> {
    const result = new DavResult();
    try {
      const response = await WebDavClient.send(config, 'GET', relPath, undefined, undefined);
      result.status = response.statusCode;
      result.ok = response.statusCode === 200;
      if (!result.ok) {
        result.message = `GET ${response.statusCode} ${response.reasonPhrase ?? ''}`.trim();
        return result;
      }
      result.message = WebDavClient.decode(response.body);
      return result;
    } catch (error) {
      result.message = WebDavClient.describe(error);
      return result;
    }
  }

  /** `DELETE`. A 404 is reported as success — the desired end state is "gone". */
  static async remove(config: DavConfig, relPath: string): Promise<DavResult> {
    const result = await WebDavClient.simple(config, 'DELETE', relPath, undefined);
    if (result.status === 404) {
      result.ok = true;
      result.message = '';
    }
    return result;
  }

  private static async simple(config: DavConfig, method: string, relPath: string,
    body: string | undefined): Promise<DavResult> {
    const result = new DavResult();
    try {
      const response = await WebDavClient.send(config, method, relPath, body, undefined);
      result.status = response.statusCode;
      result.ok = response.statusCode >= 200 && response.statusCode < 300;
      if (!result.ok) {
        result.message = `${method} ${response.statusCode} ${response.reasonPhrase ?? ''}`.trim();
      }
      return result;
    } catch (error) {
      result.message = WebDavClient.describe(error);
      hilog.error(DOMAIN, TAG, '%{public}s failed: %{public}s', method, result.message);
      return result;
    }
  }

  private static decode(body: ArrayBuffer | undefined): string {
    if (body === undefined || body.byteLength === 0) {
      return '';
    }
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(body));
  }

  private static describe(error: ESObject): string {
    const e = error as BusinessError;
    if (e !== undefined && e.code !== undefined) {
      return `[${e.code}] ${e.message ?? ''}`.trim();
    }
    return JSON.stringify(error);
  }
}

/**
 * WebDAV multistatus parsing.
 *
 * The server answers with the default `DAV:` namespace and a `D:` prefix, but
 * the prefix is not part of the protocol — another server may use `d:`, or none
 * at all. Every pattern below therefore allows an optional `xx:` prefix and
 * matches on the local name only.
 */
export class DavXml {
  /**
   * @param xml raw multistatus body
   * @param baseUrl configured base, e.g. `https://host/dav/`
   * @param requestPath the path we asked about, so the collection itself can be skipped
   */
  static parseMultiStatus(xmlText: string, baseUrl: string, requestPath: string): DavEntry[] {
    if (xmlText.trim().length === 0) {
      return [];
    }
    return DavXml.collect(xmlText, baseUrl, DavXml.normalisePath(requestPath));
  }

  /**
   * Splits the document at `<...response` boundaries.
   *
   * A real tree walk would need to know when `</response>` arrives, and the
   * pull parser's `tagValueCallbackFunction` only fires for elements that carry
   * text — so `<response>` itself is invisible and entry boundaries are lost.
   * Splitting is safe here because `multistatus` is machine-generated and
   * `response` never nests inside another `response`.
   */
  private static collect(xmlText: string, baseUrl: string, ignorePath: string): DavEntry[] {
    const entries: DavEntry[] = [];
    const chunks = xmlText.split(/<(?:\w+:)?response\b/i);
    for (let i = 1; i < chunks.length; i++) {
      const chunk = chunks[i];
      const href = DavXml.firstTagText(chunk, 'href');
      if (href.length === 0) {
        continue;
      }
      const relPath = DavXml.toRelPath(href, baseUrl);
      if (relPath.length === 0 || relPath === ignorePath) {
        continue;
      }
      const entry = new DavEntry();
      entry.relPath = relPath;
      entry.isDir = /<(?:\w+:)?collection\b/i.test(chunk);
      if (!entry.isDir) {
        const size = parseInt(DavXml.firstTagText(chunk, 'getcontentlength'), 10);
        entry.size = Number.isNaN(size) ? -1 : size;
      }
      const modified = DavXml.firstTagText(chunk, 'getlastmodified');
      if (modified.length > 0) {
        const parsed = Date.parse(modified);
        entry.modifiedAt = Number.isNaN(parsed) ? 0 : parsed;
      }
      entry.etag = DavXml.firstTagText(chunk, 'getetag');
      entries.push(entry);
    }
    return entries;
  }

  private static firstTagText(chunk: string, tag: string): string {
    const re = new RegExp('<(?:\\w+:)?' + tag + '\\b[^>]*>([\\s\\S]*?)</(?:\\w+:)?' + tag + '>', 'i');
    const match = re.exec(chunk);
    if (match === null) {
      return '';
    }
    return DavXml.unescape(match[1].trim());
  }

  private static unescape(text: string): string {
    return text
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&quot;/g, '"')
      .replace(/&apos;/g, "'")
      .replace(/&#39;/g, "'")
      .replace(/&amp;/g, '&');
  }

  private static localName(name: string): string {
    const colon = name.lastIndexOf(':');
    return colon >= 0 ? name.slice(colon + 1) : name;
  }

  /** Absolute href → path relative to the base; decodes %-escapes. */
  private static toRelPath(href: string, baseUrl: string): string {
    let path = href;
    try {
      if (/^https?:\/\//i.test(href)) {
        const absolute = new url.URL(href);
        path = absolute.pathname;
      }
    } catch (error) {
      path = href;
    }
    const basePath = new url.URL(baseUrl).pathname;
    if (path.startsWith(basePath)) {
      path = path.slice(basePath.length);
    }
    path = path.replace(/^\/+/, '');
    if (path.endsWith('/')) {
      path = path.slice(0, -1);
    }
    try {
      return decodeURIComponent(path);
    } catch (error) {
      return path;
    }
  }

  private static normalisePath(path: string): string {
    const trimmed = path.replace(/^\/+/, '').replace(/\/+$/, '');
    try {
      return decodeURIComponent(trimmed);
    } catch (error) {
      return trimmed;
    }
  }
}

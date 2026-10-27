import { rcp } from '@kit.RemoteCommunicationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';
import { SettingsStore } from './SettingsStore';
import { AiKey } from './AiKey';

const DOMAIN = 0x0000;
const TAG = 'ZhijianAi';

/** 三个场景的编号，与 `SettingsStore.modelFor()` 的约定一致。 */
export const AI_INSIGHT: number = 0;
export const AI_TRANSLATE: number = 1;
export const AI_POLISH: number = 2;

/** 一次请求的结果。`ok` 为假时 `message` 是给用户看的一句话。 */
export class AiReply {
  ok: boolean = false;
  text: string = '';
  message: string = '';
}

/**
 * OpenAI 兼容的对话补全客户端。
 *
 * ## 为什么是「OpenAI 兼容」而不是某一家 SDK
 *
 * 这一条接口是事实标准：`POST {base}/chat/completions`，请求体三个字段
 * （`model` / `messages` / `stream`），响应 `choices[0].message.content`。
 * 云端服务、企业自建、本机 llama.cpp / Ollama / vLLM 全都说这一套，所以
 * 用户只填一个地址就能接上任何一种——这正是设置页那一组的形态。
 *
 * ## 为什么允许空 key
 *
 * 本机或内网节点通常不校验鉴权。之前的 `configured` 要求 endpoint 与 key
 * 同时非空，等于把「局域网里跑的小模型」判成没配置好，用户填完地址却发现
 * 按钮还是灰的。现在只有 endpoint 是必要条件：没有 key 就不发
 * `Authorization`，而不是发一个空的。
 *
 * ## 明文 HTTP
 *
 * RCP 自 API 23 起默认**禁止**明文 HTTP，所以在
 * `resources/base/profile/network_config.json` 里对 Remote Communication Kit
 * 打开了明文。这是这一组设置的前提：一个只能填 https 的「OpenAI 兼容地址」
 * 会排除掉所有本机 / 内网节点，而它们恰恰是最常见的自建形态。
 */
export class AiClient {
  /**
   * 跑一次补全。
   *
   * `scenario` 决定用哪个模型；`system` / `user` 由调用方给，因为这个类不该
   * 知道「润色」和「格式修正」的提示词该怎么写——那是产品文案，跟着界面走。
   */
  static async chat(scenario: number, system: string, user: string): Promise<AiReply> {
    const reply = new AiReply();
    const settings = SettingsStore.instance;
    const endpoint: string = AiClient.trimSlash(settings.aiEndpoint);
    if (endpoint.length === 0) {
      reply.message = '先在设置 › AI 里填写接口地址';
      return reply;
    }
    const model: string = settings.modelFor(scenario);
    if (model.length === 0) {
      reply.message = '先在设置 › AI 里填写该场景的模型名';
      return reply;
    }

    const body: string = JSON.stringify(AiClient.payload(model, system, user));
    const key: string = await AiKey.load();
    const headers: rcp.RequestHeaders = {
      'content-type': 'application/json',
      'accept': 'application/json'
    };
    if (key.length > 0) {
      // 空 key 不发头：某些兼容实现看到 `Bearer ` 后面什么都没有会直接 401。
      headers['authorization'] = `Bearer ${key}`;
    }

    const conf: rcp.SessionConfiguration = { headers: { 'user-agent': 'Zhijian/1.0' } };
    const session = rcp.createSession(conf);
    try {
      const request = new rcp.Request(`${endpoint}/chat/completions`, 'POST', headers, body);
      // 推理型模型的第一个 token 可能等十几秒；30 s 的传输超时会把「慢」误报成
      // 「失败」，而重试一次又是十几秒。给足两分钟，只给一次机会。
      request.configuration = { transfer: { timeout: { connectMs: 10000, transferMs: 120000 } } };
      const response = await session.fetch(request);
      const text: string = AiClient.decode(response.body);      if (response.statusCode < 200 || response.statusCode >= 300) {
        reply.message = `接口返回 ${response.statusCode}${AiClient.shortReason(text)}`;
        hilog.warn(DOMAIN, TAG, 'chat %{public}d: %{public}s', response.statusCode,
          text.substring(0, Math.min(300, text.length)));
        return reply;
      }
      const content: string = AiClient.extractContent(text);
      if (content.length === 0) {
        reply.message = '接口没有返回内容';
        hilog.warn(DOMAIN, TAG, 'empty content: %{public}s', text.substring(0, Math.min(300, text.length)));
        return reply;
      }
      reply.ok = true;
      reply.text = content;
      return reply;
    } catch (error) {
      reply.message = AiClient.describe(error);
      hilog.error(DOMAIN, TAG, 'chat failed: %{public}s', reply.message);
      return reply;
    } finally {
      // 一次请求一个会话、用完即关：这里的调用是用户点一下才发生的，复用会话
      // 省不下什么，反而在失败路径上会留下连接。
      session.close();
    }
  }

  /** 把地址尾部的 `/` 去掉，再统一拼 `/chat/completions`。 */
  private static trimSlash(endpoint: string): string {
    let out: string = endpoint.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /**
   * 请求体。
   *
   * 用 `class` 而不是对象字面量：ArkTS 拒绝无类型字面量
   * （`arkts-no-untyped-obj-literals`），`JSON.stringify` 的入参也不例外。
   */
  private static payload(model: string, system: string, user: string): ChatRequest {
    const req = new ChatRequest();
    req.model = model;
    req.stream = false;
    // 这三个场景都要「按原样改文字」，温度高了就自己编内容。
    req.temperature = 0.3;
    const sys = new ChatMessage();
    sys.role = 'system';
    sys.content = system;
    const usr = new ChatMessage();
    usr.role = 'user';
    usr.content = user;
    req.messages = [sys, usr];
    return req;
  }

  private static decode(body: ArrayBuffer | undefined): string {
    if (body === undefined) {
      return '';
    }
    const decoder = util.TextDecoder.create('utf-8');
    return decoder.decodeToString(new Uint8Array(body));
  }

  /**
   * 取 `choices[0].message.content`。
   *
   * 不用 `JSON.parse` 之后逐层断言：ArkTS 的 `JSON.parse` 返回 `Object`，
   * 往深里取字段要么全用 `ESObject`（禁），要么写一整套 `as` 链（一层不存在
   * 就抛）。这里只需要**一个**字符串，按出现的第一个 `"content":"…"` 取更稳，
   * 而且兼容那些在响应里多塞字段的实现。
   *
   * 代价是必须处理转义。`\n` / `\"` / `\\` / `\uXXXX` 四种足以覆盖模型输出；
   * 其余控制转义按「反斜杠 + 原字符」原样保留，宁可多一个反斜杠，也不要把
   * 正文吃掉。
   */
  private static extractContent(raw: string): string {
    const marker: string = '"content"';
    let from: number = raw.indexOf(marker);
    while (from >= 0) {
      let i: number = raw.indexOf(':', from + marker.length);
      if (i < 0) {
        return '';
      }
      i++;
      while (i < raw.length && (raw.charAt(i) === ' ' || raw.charAt(i) === '\n' || raw.charAt(i) === '\r')) {
        i++;
      }
      if (raw.charAt(i) !== '"') {
        // `"content": null` 之类，跳到下一个候选。
        from = raw.indexOf(marker, from + marker.length);
        continue;
      }
      return AiClient.readJsonString(raw, i + 1);
    }
    return '';
  }

  /** 从 `start`（引号之后）读一个 JSON 字符串，处理转义。 */
  private static readJsonString(raw: string, start: number): string {
    const out: string[] = [];
    let i: number = start;
    while (i < raw.length) {
      const ch: string = raw.charAt(i);
      if (ch === '"') {
        return out.join('');
      }
      if (ch !== '\\') {
        out.push(ch);
        i++;
        continue;
      }
      if (i + 1 >= raw.length) {
        break;
      }
      const esc: string = raw.charAt(i + 1);
      if (esc === 'n') {
        out.push('\n');
      } else if (esc === 't') {
        out.push('\t');
      } else if (esc === 'r') {
        out.push('\r');
      } else if (esc === 'b') {
        out.push('\b');
      } else if (esc === 'f') {
        out.push('\f');
      } else if (esc === '"' || esc === '\\' || esc === '/') {
        out.push(esc);
      } else if (esc === 'u' && i + 5 < raw.length) {
        const code: number = parseInt(raw.substring(i + 2, i + 6), 16);
        if (!isNaN(code)) {
          out.push(String.fromCharCode(code));
          i += 6;
          continue;
        }
        out.push(esc);
      } else {
        // 未知转义：保留原样，别把正文吃掉。
        out.push('\\');
        out.push(esc);
      }
      i += 2;
    }
    return out.join('');
  }

  /** 把错误响应里的 `"message"` 摘出来，让提示能说明原因。 */
  private static shortReason(raw: string): string {
    const text: string = AiClient.extractKey(raw, '"message"');
    if (text.length === 0) {
      return '';
    }
    return ` · ${text.substring(0, Math.min(80, text.length))}`;
  }

  private static extractKey(raw: string, marker: string): string {
    const from: number = raw.indexOf(marker);
    if (from < 0) {
      return '';
    }
    let i: number = raw.indexOf(':', from + marker.length);
    if (i < 0) {
      return '';
    }
    i++;
    while (i < raw.length && (raw.charAt(i) === ' ' || raw.charAt(i) === '\n')) {
      i++;
    }
    if (raw.charAt(i) !== '"') {
      return '';
    }
    return AiClient.readJsonString(raw, i + 1);
  }

  private static describe(error: ESObject): string {
    const e = error as BusinessError;
    if (e !== undefined && e.code !== undefined) {
      return `请求失败 [${e.code}] ${e.message ?? ''}`.trim();
    }
    return '请求失败：网络不可达';
  }
}

/** 请求体：只声明用到的字段，`JSON.stringify` 会原样展开。 */
class ChatMessage {
  role: string = 'user';
  content: string = '';
}

class ChatRequest {
  model: string = '';
  messages: ChatMessage[] = [];
  stream: boolean = false;
  temperature: number = 0.3;
}

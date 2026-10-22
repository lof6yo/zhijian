import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0000;
const TAG = 'ZhijianSecret';
const ALIAS = 'zhijian.webdav';

/**
 * WebDAV credentials.
 *
 * The password lives in **Asset Store Kit**, not `preferences` and never in
 * source. `preferences` is a plain XML file in the app sandbox — readable on a
 * rooted or backed-up device and trivially greppable in a dump. Asset Store
 * encrypts at rest, is gated behind the app's own signature, and offers no API
 * to enumerate secrets, which is the platform's answer for exactly this.
 *
 * The username and base URL are not secrets, so they stay in `SettingsStore`
 * where the settings page can render them without a keystore round trip.
 */
export class Credentials {
  /** Reads the stored password; empty string when absent. */
  static async loadPassword(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, Credentials.toBytes(ALIAS));
      query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
      const result: asset.AssetMap[] = await asset.query(query);
      if (result.length === 0) {
        return '';
      }
      const secret = result[0].get(asset.Tag.SECRET);
      if (secret === undefined) {
        return '';
      }
      return util.TextDecoder.create('utf-8').decodeToString(secret as Uint8Array);
    } catch (error) {
      const e = error as BusinessError;
      // 24000002 = NOT_FOUND: first run, not an error worth logging loudly.
      if (e.code !== 24000002) {
        hilog.error(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(error));
      }
      return '';
    }
  }

  /** Adds or replaces the stored password. */
  static async savePassword(password: string): Promise<boolean> {
    try {
      // `asset.add` throws if the alias exists, so remove first. Removing a
      // missing alias is a no-op error worth ignoring.
      await Credentials.removePassword();
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.ALIAS, Credentials.toBytes(ALIAS));
      attrs.set(asset.Tag.SECRET, Credentials.toBytes(password));
      attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      await asset.add(attrs);
      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'save failed: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  /** Removes the stored password; safe when nothing is stored. */
  static async removePassword(): Promise<void> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, Credentials.toBytes(ALIAS));
      await asset.remove(query);
    } catch (error) {
      const e = error as BusinessError;
      if (e.code !== 24000002) {
        hilog.warn(DOMAIN, TAG, 'remove failed: %{public}s', JSON.stringify(error));
      }
    }
  }

  private static toBytes(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }
}

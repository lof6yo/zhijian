import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { util } from '@kit.ArkTS';

const DOMAIN = 0x0000;
const TAG = 'ZhijianAiKey';
const ALIAS = 'zhijian.ai';

/**
 * AI 服务密钥（OpenAI 兼容服务的 `Authorization: Bearer …`）。
 *
 * 与 WebDAV 密码同样的处理：**只**进 Asset Store Kit，不进 `preferences`、
 * 不进源码、不进日志。`preferences` 是沙箱里的一份明文 XML —— 备份、root、
 * 甚至一次 `hdc file recv` 都能把它读走；Asset Store 静态加密、绑定应用签名，
 * 且没有枚举接口，这正是平台为「一串长期有效的密钥」准备的容器。
 *
 * endpoint 与模型名不是秘密，留在 `SettingsStore` 里，设置页渲染时不必每次
 * 都过一次密钥库。
 */
export class AiKey {
  /** 读已保存的密钥；没有时返回空串。 */
  static async load(): Promise<string> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, AiKey.toBytes(ALIAS));
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
      // 24000002 = NOT_FOUND：第一次运行，不是需要大声记录的故障。
      if (e.code !== 24000002) {
        hilog.error(DOMAIN, TAG, 'load failed: %{public}s', JSON.stringify(error));
      }
      return '';
    }
  }

  /** 新增或替换。`asset.add` 在别名已存在时会抛错，所以先删。 */
  static async save(key: string): Promise<boolean> {
    try {
      await AiKey.remove();
      const attrs: asset.AssetMap = new Map();
      attrs.set(asset.Tag.ALIAS, AiKey.toBytes(ALIAS));
      attrs.set(asset.Tag.SECRET, AiKey.toBytes(key));
      attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      await asset.add(attrs);
      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'save failed: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  /** 删除；没有存过时是合法的空操作。 */
  static async remove(): Promise<void> {
    try {
      const query: asset.AssetMap = new Map();
      query.set(asset.Tag.ALIAS, AiKey.toBytes(ALIAS));
      await asset.remove(query);
    } catch (error) {
      const e = error as BusinessError;
      if (e.code !== 24000002) {
        hilog.warn(DOMAIN, TAG, 'remove failed: %{public}s', JSON.stringify(error));
      }
    }
  }

  /**
   * 把可用的配置拼成一份快照。
   *
   * **只有 endpoint 是必要条件**：本机或内网节点通常不校验鉴权，把 key 也算进
   * 「配好了吗」会把它们判成没配好——用户填完地址却发现按钮还是灰的。key 存在
   * 与否只用来决定占位文案。
   */
  static async snapshot(endpoint: string): Promise<AiConfigState> {
    const key: string = await AiKey.load();
    const state = new AiConfigState();
    state.endpoint = endpoint;
    state.keyPresent = key.length > 0;
    state.configured = endpoint.trim().length > 0;
    return state;
  }

  private static toBytes(value: string): Uint8Array {
    return new util.TextEncoder().encodeInto(value);
  }
}

/** 设置页渲染用的一份状态快照：只有布尔量，不含密钥本身。 */
export class AiConfigState {
  endpoint: string = '';
  keyPresent: boolean = false;
  configured: boolean = false;
}

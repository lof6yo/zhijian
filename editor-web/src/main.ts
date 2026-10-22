import { Crepe } from '@milkdown/crepe';
import { replaceAll } from '@milkdown/kit/utils';
// Individual Crepe theme pieces instead of `theme/common/style.css`: that barrel
// imports latex.css (KaTeX @font-face SVG base64, ~1.4 MB) plus table/ai/diff/
// top-bar styles for features this editor does not enable.
import '@milkdown/crepe/theme/common/prosemirror.css';
import '@milkdown/crepe/theme/common/reset.css';
import '@milkdown/crepe/theme/common/block-edit.css';
import '@milkdown/crepe/theme/common/code-mirror.css';
import '@milkdown/crepe/theme/common/cursor.css';
import '@milkdown/crepe/theme/common/image-block.css';
import '@milkdown/crepe/theme/common/link-tooltip.css';
import '@milkdown/crepe/theme/common/list-item.css';
import '@milkdown/crepe/theme/common/placeholder.css';
import '@milkdown/crepe/theme/common/toolbar.css';
import '@milkdown/crepe/theme/frame.css';
import './style.css';

declare global {
  interface Window {
    native?: {
      save?: (markdown: string) => void;
      ready?: () => void;
      pickImage?: () => void;
    };
    __setMarkdown?: (markdown: string) => Promise<void>;
    __setTheme?: (theme: string) => void;
    __setTypography?: (fontSize: number, lineHeight: number) => void;
    __setAccent?: (color: string) => void;
    __HM_INITIAL_MD__?: string;
  }
}

const root = document.getElementById('app');
if (!root) {
  throw new Error('editor root missing');
}

let crepe: Crepe | null = null;
/** Guards the `native.save` bridge against programmatic document replacement. */
let suppress = false;
/** Set/markdown state from the last `__setMarkdown`; used for debugging only. */
let lastMarkdown: string | null = null;
/** In-flight (or settled) creation; every `__setMarkdown` awaits it. */
let creation: Promise<void> | null = null;

function showLoading(): void {
  const div = document.createElement('div');
  div.className = 'hm-editor-loading';
  div.textContent = '加载中…';
  root!.replaceChildren(div);
}

function hideLoading(): void {
  root!.querySelector('.hm-editor-loading')?.remove();
}

async function createEditor(): Promise<void> {
  if (!crepe) {
    crepe = new Crepe({
      root,
      // The document arrives through `__setMarkdown`; an empty default keeps the
      // first parse cheap and avoids rendering a throwaway document.
      defaultValue: '',
      features: {
        [Crepe.Feature.Latex]: false,
        [Crepe.Feature.Table]: false,
        [Crepe.Feature.AI]: false,
        [Crepe.Feature.TopBar]: false
      }
    });
    crepe.on((listener) => {
      listener.markdownUpdated((_ctx, md) => {
        if (suppress) {
          return;
        }
        lastMarkdown = md;
        window.native?.save?.(md);
      });
    });
  }
  await crepe.create();
  hideLoading();
  window.native?.ready?.();
}

/**
 * Creates the editor exactly once, then replaces the document in place.
 * The native page calls this on `onPageEnd`; a repeated call reuses the existing
 * instance via `replaceAll` instead of destroying and rebuilding Crepe.
 */
window.__setMarkdown = async (markdown: string): Promise<void> => {
  suppress = true;
  try {
    if (!creation) {
      creation = createEditor().catch((error: Error) => {
        // Allow a later call to retry after a failed creation.
        creation = null;
        root!.textContent = `Editor failed: ${error.message}`;
      });
    }
    await creation;
    const editor = crepe?.editor;
    if (editor) {
      editor.action(replaceAll(markdown));
      lastMarkdown = markdown;
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    root!.textContent = `Editor failed: ${message}`;
  } finally {
    suppress = false;
  }
};

window.__setTheme = (theme: string): void => {
  document.documentElement.dataset.theme = theme;
};

/**
 * Typography is applied through CSS variables rather than by rebuilding Crepe:
 * the ProseMirror stylesheet already binds font-size/line-height to
 * `--hm-font-size` / `--hm-line-height`, so a variable write repaints in place.
 */
window.__setTypography = (fontSize: number, lineHeight: number): void => {
  const style = document.documentElement.style;
  if (Number.isFinite(fontSize) && fontSize > 0) {
    style.setProperty('--hm-font-size', `${fontSize}px`);
  }
  if (Number.isFinite(lineHeight) && lineHeight > 0) {
    style.setProperty('--hm-line-height', `${lineHeight}`);
  }
};

/** Accent comes from the native palette so editor links/quotes/caret match the app. */
window.__setAccent = (color: string): void => {
  if (/^#[0-9a-fA-F]{6,8}$/.test(color)) {
    document.documentElement.style.setProperty('--hm-accent', color);
  }
};

// No eager Crepe initialization: the native shell injects the note body through
// `__setMarkdown` right after `onPageEnd`, so building an editor with a default
// document here would only duplicate the startup cost.
showLoading();

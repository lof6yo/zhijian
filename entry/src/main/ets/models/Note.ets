@ObservedV2
export class Note {
  id: string = '';
  @Trace title: string = '';
  @Trace body: string = '';
  @Trace tags: string[] = [];
  /**
   * 是否已归档。
   *
   * 归档是「收起来」而不是「扔掉」：笔记仍然在磁盘上、仍然参与同步，只是不在
   * 「全部」里露面，只在「已归档」里。所以它和 `favorite` 一样是笔记自己的
   * 属性（写在 frontmatter 里），而不是回收站那种删除。
   */
  @Trace archived: boolean = false;
  @Trace favorite: boolean = false;
  @Trace updatedAt: number = 0;
  createdAt: number = 0;
  @Trace relPath: string = '';
  @Trace folder: string = '';
  @Trace excerpt: string = '';
}

export class TrashEntry {
  fileName: string = '';
  title: string = '';
  deletedAt: number = 0;
  size: number = 0;
}

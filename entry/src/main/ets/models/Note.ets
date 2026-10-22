@ObservedV2
export class Note {
  id: string = '';
  @Trace title: string = '';
  @Trace body: string = '';
  @Trace tags: string[] = [];
  @Trace pinned: boolean = false;
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

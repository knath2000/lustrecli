export function moveQueuedJob(ids: string[], sourceID: string, targetID: string) {
  const sourceIndex = ids.indexOf(sourceID);
  const targetIndex = ids.indexOf(targetID);
  if (sourceIndex < 0 || targetIndex < 0 || sourceIndex === targetIndex) return ids;
  const next = [...ids];
  const [source] = next.splice(sourceIndex, 1);
  next.splice(targetIndex, 0, source);
  return next;
}

export function moveQueuedJobByOffset(ids: string[], id: string, offset: -1 | 1) {
  const index = ids.indexOf(id);
  const target = index + offset;
  if (index < 0 || target < 0 || target >= ids.length) return ids;
  return moveQueuedJob(ids, id, ids[target]);
}

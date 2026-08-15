export const previewCommandURLLimit = 10;

export function previewURLBatches(urls: string[]) {
  const batches: string[][] = [];
  for (let start = 0; start < urls.length; start += previewCommandURLLimit) {
    batches.push(urls.slice(start, start + previewCommandURLLimit));
  }
  return batches;
}

import assert from "node:assert/strict";
import { chmod, mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { resolveWithYtDlp } from "../src/ytdlp";

test("yt-dlp invocation parses and bounds safe qualities", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "lustre-ytdlp-"));
  const binary = path.join(directory, "yt-dlp");
  await writeFile(binary, `#!/bin/sh
printf '%s' '{"title":"Fixture","formats":[{"url":"https://cdn.example/video.mp4","format_note":"1080p"},{"url":"http://unsafe.example/video.mp4","format_note":"bad"}]}'
`);
  await chmod(binary, 0o755);
  const result = await resolveWithYtDlp("https://www.pornhub.com/view_video.php?viewkey=abc", binary);
  assert.equal(result.qualities.length, 1);
  assert.equal(result.qualities[0]?.label, "1080p");
});

test("yt-dlp verification failures map to stable error", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "lustre-ytdlp-"));
  const binary = path.join(directory, "yt-dlp");
  await writeFile(binary, "#!/bin/sh\necho 'captcha verification required' >&2\nexit 1\n");
  await chmod(binary, 0o755);
  await assert.rejects(resolveWithYtDlp("https://www.pornhub.com/view_video.php?viewkey=abc", binary), (error: { code?: string }) => error.code === "verification_required");
});

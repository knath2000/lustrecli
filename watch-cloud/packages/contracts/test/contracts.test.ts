import assert from "node:assert/strict";
import test from "node:test";
import { feedPlaybackResolutionSchema } from "../src/index";

const resolution = {
  sourcePageURL: "https://vidara.so/v/code",
  title: "Fixture",
  qualities: [{
    label: "720p",
    url: "https://media.example/master.m3u8",
    mediaKind: "hls",
    headers: {},
  }],
};

test("playback qualities remain backward compatible without Infuse compatibility", () => {
  assert.equal(feedPlaybackResolutionSchema.parse(resolution).qualities[0]?.infuseCompatibility, undefined);
});

test("playback qualities accept bounded Infuse compatibility states", () => {
  for (const infuseCompatibility of ["verified", "header_required", "unknown"] as const) {
    assert.equal(feedPlaybackResolutionSchema.parse({
      ...resolution,
      qualities: [{ ...resolution.qualities[0], infuseCompatibility }],
    }).qualities[0]?.infuseCompatibility, infuseCompatibility);
  }
  assert.throws(() => feedPlaybackResolutionSchema.parse({
    ...resolution,
    qualities: [{ ...resolution.qualities[0], infuseCompatibility: "unsafe" }],
  }));
});

import { describe, expect, it } from 'vitest';
import { SourceMapConsumer, SourceNode } from 'source-map-js';

const basic = { version: 3, sources: ['input.js'], names: [], mappings: 'AAAA', sourcesContent: ['x'] };
const indexed = (line, map = basic) => ({ version: 3, sections: [{ offset: { line, column: 0 }, map }] });

describe('indexed source-map security boundary', () => {
  // Construction alone tests rejection; never expand a hostile map into lines.
  it.each([-1, 0.5, Infinity, Number.MAX_SAFE_INTEGER])('rejects invalid or unbounded section line %s', line => {
    expect(() => new SourceMapConsumer(indexed(line))).toThrow(/offset/i);
  });
  it('rejects nested offsets whose cumulative line exceeds the safe bound', () => {
    expect(() => new SourceMapConsumer(indexed(6_000_000, indexed(6_000_000)))).toThrow(/offset/i);
  });
  it('preserves normal indexed-map positions and generated content', () => {
    const consumer = new SourceMapConsumer(indexed(0));
    const mappings = [];
    consumer.eachMapping(mapping => mappings.push(mapping));
    expect(mappings).toEqual([{ source: 'input.js', generatedLine: 1, generatedColumn: 0, originalLine: 1, originalColumn: 0, name: null }]);
    expect(SourceNode.fromStringWithSourceMap('x', consumer).toString()).toBe('x');
  });
});

import{readFileSync}from"node:fs";import{describe,expect,it}from"vitest";
describe("Phase 2H governed review UI",()=>{const dashboard=readFileSync(new URL("../dashboard.js",import.meta.url),"utf8"),admin=readFileSync(new URL("../admin.js",import.meta.url),"utf8");
it("shows players a safe non-private review banner",()=>{expect(dashboard).toContain("Competition under review");expect(dashboard).toContain("Picks and history remain safe");expect(dashboard).not.toContain("item.evidence");});
it("shows admin cases, previews and stale-state handling",()=>{expect(admin).toContain("Governed review");expect(admin).toContain("Preview resolution");expect(admin).toContain("Resolution reason (required)");expect(admin).toContain("Review state changed; preview again.");});});

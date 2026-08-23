import { readFileSync } from "node:fs";
import { describe,expect,it } from "vitest";
describe("Phase 2G completed-pot UI",()=>{
 const dashboard=readFileSync(new URL("../dashboard.js",import.meta.url),"utf8"); const admin=readFileSync(new URL("../admin.js",import.meta.url),"utf8");
 it("shows winner names, total and own share",()=>{expect(dashboard).toContain('names.length===1?"Winner":"Winners"');expect(dashboard).toContain("Prize pot:");expect(dashboard).toContain("Your share:");expect(dashboard).toContain("Players with an unused buy-back shared the pot.");});
 it("shows the admin immutable winner/share summary",()=>{expect(admin).toContain("Final winners");expect(admin).toContain("prize_share_pence");expect(admin).not.toContain("Crown ${player");});
});

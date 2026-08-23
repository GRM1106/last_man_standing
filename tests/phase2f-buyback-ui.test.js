import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
describe("Phase 2F buy-back lifecycle UI", () => {
 const dashboard=readFileSync(new URL("../dashboard.js",import.meta.url),"utf8"); const admin=readFileSync(new URL("../admin.js",import.meta.url),"utf8");
 it("shows provisional, confirmed, used and closed-window states",()=>{ expect(dashboard).toContain("Buy-back requested — you're back in the game"); expect(dashboard).toContain("You can participate in the next round now"); expect(dashboard).toContain("Buy-back already used — you are eliminated"); expect(dashboard).toContain("Buy-back window closed"); });
 it("separates confirmation from reasoned revocation",()=>{ expect(admin).toContain("Confirm ${money(pot.buy_back_fee_pence)} payment"); expect(admin).toContain("Revoke buy-back"); expect(admin).toContain('supabase.rpc("revoke_buy_back"'); expect(admin).toContain("Reason for revoking this buy-back (required)"); });
});

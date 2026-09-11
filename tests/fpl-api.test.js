import { afterEach, describe, expect, it, vi } from "vitest";
import handler from "../api/fpl.js";

const bootstrap = {
  teams: [
    { id: 1, code: 10, name: "Alpha FC", short_name: "ALP", ignored: true },
    { id: 2, code: 20, name: "Beta FC", short_name: "BET", ignored: true }
  ]
};

const fixtures = [
  {
    id: 101,
    event: 1,
    kickoff_time: "2026-08-22T14:00:00Z",
    team_h: 1,
    team_a: 2,
    team_h_score: 2,
    team_a_score: 1,
    started: true,
    finished: true,
    finished_provisional: false,
    provisional_start_time: false,
    ignored: true
  }
];

function responseRecorder() {
  const response = {
    setHeader: vi.fn(),
    status: vi.fn(),
    json: vi.fn()
  };
  response.status.mockReturnValue(response);
  response.json.mockReturnValue(response);
  return response;
}

function successfulFetch() {
  return vi.fn()
    .mockResolvedValueOnce({ ok: true, json: vi.fn().mockResolvedValue(bootstrap) })
    .mockResolvedValueOnce({ ok: true, json: vi.fn().mockResolvedValue(fixtures) });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("FPL serverless proxy", () => {
  it("imports as ESM and exports a callable default handler", () => {
    expect(handler).toBeTypeOf("function");
  });

  it("returns the filtered FPL payload and cache policy on success", async () => {
    const fetchMock = successfulFetch();
    vi.stubGlobal("fetch", fetchMock);
    const response = responseRecorder();

    await handler({ method: "GET" }, response);

    expect(fetchMock).toHaveBeenNthCalledWith(1, "https://fantasy.premierleague.com/api/bootstrap-static/", expect.objectContaining({ cache: "no-store", signal: expect.any(AbortSignal) }));
    expect(fetchMock).toHaveBeenNthCalledWith(2, "https://fantasy.premierleague.com/api/fixtures/", expect.objectContaining({ cache: "no-store", signal: expect.any(AbortSignal) }));
    expect(response.setHeader).toHaveBeenCalledWith("Cache-Control", "s-maxage=900, stale-while-revalidate=3600");
    expect(response.status).toHaveBeenCalledWith(200);
    expect(response.json).toHaveBeenCalledWith({
      teams: [{ id: 1, code: 10, name: "Alpha FC", short_name: "ALP" }, { id: 2, code: 20, name: "Beta FC", short_name: "BET" }],
      fixtures: [{
        id: 101,
        event: 1,
        kickoff_time: "2026-08-22T14:00:00Z",
        team_h: 1,
        team_a: 2,
        team_h_score: 2,
        team_a_score: 1,
        started: true,
        finished: true,
        finished_provisional: false,
        provisional_start_time: false
      }]
    });
  });

  it("returns the intended safe response when an upstream HTTP request fails", async () => {
    vi.stubGlobal("fetch", vi.fn()
      .mockResolvedValueOnce({ ok: false })
      .mockResolvedValueOnce({ ok: true }));
    const response = responseRecorder();

    await handler({ method: "GET" }, response);

    expect(response.status).toHaveBeenCalledWith(502);
    expect(response.json).toHaveBeenCalledWith({ error: "The FPL feed returned an unsuccessful response." });
  });

  it("does not expose internal exception details", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("private upstream detail")));
    const response = responseRecorder();

    await handler({ method: "GET" }, response);

    expect(response.status).toHaveBeenCalledWith(502);
    expect(response.json).toHaveBeenCalledWith({ error: "Could not reach the FPL feed." });
  });

  it("rejects unsupported methods before contacting the provider", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    const response = responseRecorder();

    await handler({ method: "POST" }, response);

    expect(fetchMock).not.toHaveBeenCalled();
    expect(response.setHeader).toHaveBeenCalledWith("Allow", "GET");
    expect(response.status).toHaveBeenCalledWith(405);
    expect(response.json).toHaveBeenCalledWith({ error: "Method not allowed." });
  });
});

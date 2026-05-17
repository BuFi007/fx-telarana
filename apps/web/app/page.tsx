// SPDX-License-Identifier: MIT
export const dynamic = "force-dynamic";

type MarketState = {
  totalSupplyAssets?: string;
  totalBorrowAssets?: string;
};

type Market = {
  id: string;
  hubName?: string;
  hubChainId: number;
  loanToken: string;
  collateralToken: string;
  isLive?: boolean;
  state?: MarketState | null;
};

type MarketsPayload = {
  markets: Market[];
};

type TvlPayload = {
  tvl: Record<string, string>;
  borrowed: Record<string, string>;
};

type LiquidationPayload = {
  source: string;
  candidates: Array<{
    id?: string;
    market?: string;
    account?: string;
    healthFactor?: string | null;
    rank?: number;
  }>;
};

function apiBaseUrl(): string {
  return process.env.FX_TELARANA_API_URL ?? process.env.NEXT_PUBLIC_FX_TELARANA_API_URL ?? "http://localhost:3002";
}

async function fetchApi<T>(path: string): Promise<T | null> {
  try {
    const response = await fetch(new URL(path, apiBaseUrl()), { cache: "no-store" });
    if (!response.ok) return null;
    return (await response.json()) as T;
  } catch {
    return null;
  }
}

function shortAddress(value: string): string {
  return `${value.slice(0, 6)}...${value.slice(-4)}`;
}

function formatRaw(value: string | undefined): string {
  if (!value) return "0";
  const raw = BigInt(value);
  if (raw >= 1_000_000_000_000n) return `${raw / 1_000_000_000_000n}T raw`;
  if (raw >= 1_000_000_000n) return `${raw / 1_000_000_000n}B raw`;
  if (raw >= 1_000_000n) return `${raw / 1_000_000n}M raw`;
  return `${raw.toString()} raw`;
}

function utilization(state?: MarketState | null): string {
  const supply = BigInt(state?.totalSupplyAssets ?? "0");
  const borrow = BigInt(state?.totalBorrowAssets ?? "0");
  if (supply === 0n) return "0.00%";
  const bps = (borrow * 10_000n) / supply;
  return `${bps / 100n}.${(bps % 100n).toString().padStart(2, "0")}%`;
}

function tvlTokenCount(payload: TvlPayload | null): string {
  if (!payload) return "offline";
  return `${Object.keys(payload.tvl).length} tokens`;
}

export default async function Home() {
  const [marketsPayload, tvlPayload, liquidationPayload] = await Promise.all([
    fetchApi<MarketsPayload>("/fx-telarana/markets"),
    fetchApi<TvlPayload>("/fx-telarana/tvl"),
    fetchApi<LiquidationPayload>("/fx-telarana/liquidations/candidates?limit=5"),
  ]);
  const markets = marketsPayload?.markets ?? [];
  const candidates = liquidationPayload?.candidates ?? [];

  return (
    <main className="shell">
      <aside className="rail" aria-label="Primary navigation">
        <div className="mark">FXT</div>
        <nav>
          <a aria-current="page">Markets</a>
          <a>Positions</a>
          <a>Liquidations</a>
          <a>TVL</a>
        </nav>
      </aside>

      <section className="workspace">
        <header className="topbar">
          <div>
            <h1>Loan & Borrow</h1>
            <p>Fuji and Arc isolated FX stablecoin markets</p>
          </div>
          <div className="statusStrip" aria-label="Protocol status">
            <span>{marketsPayload ? "API live" : "API offline"}</span>
            <span>TVL {tvlTokenCount(tvlPayload)}</span>
          </div>
        </header>

        <div className="grid">
          <section className="panel markets" aria-labelledby="markets-title">
            <div className="panelHeader">
              <h2 id="markets-title">Markets</h2>
              <span>{markets.length} indexed</span>
            </div>
            <table>
              <thead>
                <tr>
                  <th>Pair</th>
                  <th>Hub</th>
                  <th>Supply</th>
                  <th>Borrowed</th>
                  <th>Util.</th>
                </tr>
              </thead>
              <tbody>
                {markets.length > 0 ? (
                  markets.map((market) => (
                    <tr key={`${market.hubChainId}-${market.id}`}>
                      <td>
                        {shortAddress(market.loanToken)} / {shortAddress(market.collateralToken)}
                      </td>
                      <td>{market.hubName ?? market.hubChainId}</td>
                      <td>{formatRaw(market.state?.totalSupplyAssets)}</td>
                      <td>{formatRaw(market.state?.totalBorrowAssets)}</td>
                      <td>{utilization(market.state)}</td>
                    </tr>
                  ))
                ) : (
                  <tr>
                    <td colSpan={5} className="emptyCell">
                      No markets returned by the lending API yet.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </section>

          <section className="panel quote" aria-labelledby="quote-title">
            <div className="panelHeader">
              <h2 id="quote-title">Quote</h2>
              <span>Unsigned intents only</span>
            </div>
            <label>
              Mode
              <select defaultValue="borrow">
                <option value="supply">Supply</option>
                <option value="borrow">Borrow</option>
                <option value="repay">Repay</option>
                <option value="withdraw">Withdraw</option>
              </select>
            </label>
            <label>
              Amount
              <input inputMode="decimal" placeholder="0.00" />
            </label>
            <dl>
              <div>
                <dt>Health factor</dt>
                <dd>-</dd>
              </div>
              <div>
                <dt>Liquidation price</dt>
                <dd>-</dd>
              </div>
              <div>
                <dt>Max borrow</dt>
                <dd>-</dd>
              </div>
            </dl>
            <button type="button">Build intent</button>
          </section>
        </div>

        <div className="lowerGrid">
          <section className="panel" aria-labelledby="positions-title">
            <div className="panelHeader">
              <h2 id="positions-title">Position Preview</h2>
              <span>Wallet required</span>
            </div>
            <dl>
              <div>
                <dt>Supply shares</dt>
                <dd>-</dd>
              </div>
              <div>
                <dt>Borrow shares</dt>
                <dd>-</dd>
              </div>
              <div>
                <dt>Collateral</dt>
                <dd>-</dd>
              </div>
            </dl>
          </section>

          <section className="panel" aria-labelledby="liquidations-title">
            <div className="panelHeader">
              <h2 id="liquidations-title">Liquidation Queue</h2>
              <span>{liquidationPayload?.source ?? "offline"}</span>
            </div>
            <table>
              <thead>
                <tr>
                  <th>Rank</th>
                  <th>Account</th>
                  <th>HF</th>
                </tr>
              </thead>
              <tbody>
                {candidates.length > 0 ? (
                  candidates.map((candidate, index) => (
                    <tr key={candidate.id ?? `${candidate.account}-${candidate.market}`}>
                      <td>{candidate.rank ?? index + 1}</td>
                      <td>{candidate.account ? shortAddress(candidate.account) : "-"}</td>
                      <td>{candidate.healthFactor ?? "-"}</td>
                    </tr>
                  ))
                ) : (
                  <tr>
                    <td colSpan={3} className="emptyCell">
                      No indexed liquidation candidates.
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </section>
        </div>
      </section>
    </main>
  );
}

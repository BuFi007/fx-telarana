// SPDX-License-Identifier: MIT
const markets = [
  { pair: "USDC / EURC", hub: "Fuji", supply: "0", borrowed: "0", util: "0.00%" },
  { pair: "EURC / USDC", hub: "Fuji", supply: "0", borrowed: "0", util: "0.00%" },
  { pair: "USDC / EURC", hub: "Arc", supply: "0", borrowed: "0", util: "0.00%" },
  { pair: "EURC / USDC", hub: "Arc", supply: "0", borrowed: "0", util: "0.00%" },
];

export default function Home() {
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
          <button type="button">Connect wallet</button>
        </header>

        <div className="grid">
          <section className="panel markets" aria-labelledby="markets-title">
            <div className="panelHeader">
              <h2 id="markets-title">Markets</h2>
              <span>Live API binding pending</span>
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
                {markets.map((market) => (
                  <tr key={`${market.hub}-${market.pair}`}>
                    <td>{market.pair}</td>
                    <td>{market.hub}</td>
                    <td>{market.supply}</td>
                    <td>{market.borrowed}</td>
                    <td>{market.util}</td>
                  </tr>
                ))}
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
      </section>
    </main>
  );
}

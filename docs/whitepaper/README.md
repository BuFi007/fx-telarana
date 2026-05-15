# Telarana Whitepaper

Source:

```bash
docs/whitepaper/telarana_whitepaper.tex
```

Build with any standard LaTeX toolchain:

```bash
cd docs/whitepaper
pdflatex telarana_whitepaper.tex
pdflatex telarana_whitepaper.tex
```

The repository machine used to create this draft did not have `pdflatex`,
`latexmk`, or `tectonic` installed, so only source-level validation was run
locally.

Before public release, replace the model token ledger placeholder
`PENDING_OPENAI_USAGE_EXPORT` with the verified provider usage-export value.

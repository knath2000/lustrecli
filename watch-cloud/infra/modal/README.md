# Modal resolver deployment

Create a dedicated Modal Starter workspace and an environment named `lustre-watch`. In Modal:

- Set the dedicated workspace hard budget to `$10`.
- Configure usage notifications at `$5` and `$8`.
- Create an environment-scoped Proxy Token.

Modal currently reserves environment-level budgets for Team and Enterprise. Do not upgrade for this project: the dedicated Starter workspace’s `$10` hard budget is the enforceable outer cap and remains below the recurring `$30` Starter compute credit.

Deploy from the repository root:

```sh
python3 -m venv .venv-modal
.venv-modal/bin/pip install -r infra/modal/requirements.txt
.venv-modal/bin/modal setup
.venv-modal/bin/modal deploy --env lustre-watch infra/modal/app.py
```

Copy the deployed Web Function URL, Proxy Token ID, and Proxy Token secret into Vercel as `RESOLVER_ORIGIN`, `MODAL_PROXY_KEY`, and `MODAL_PROXY_SECRET`.

Before every release, verify the current Starter recurring credit and workspace budget enforcement in Modal’s dashboard. Do not deploy if the workspace hard cap is absent, above `$10`, or not enforced.

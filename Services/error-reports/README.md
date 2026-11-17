# Error reports and feedback service

Cloudflare Worker for automatic error reports, user-submitted feedback, feedback attachments, replies and contributor information. Reports are stored in D1; attachments are stored in R2; feedback becomes an issue in the configured GitHub repository.

Install the website's Node dependencies first so `../../website/node_modules/.bin/wrangler` is available. Before deploying, configure `wrangler.jsonc` with your own resources:

- Replace `reports.example.com` with a hostname you own.
- Create the `yingxia-reports` D1 database and replace the all-zero `database_id` with its ID. Update `database_name` if you use another name.
- Replace each `YOUR_*_NAMESPACE_ID` with a distinct numeric rate-limit namespace ID for your Cloudflare account.
- Replace `YOUR_FEEDBACK_BUCKET_NAME` with your R2 bucket name and set `FILES_URL` to its public HTTPS origin.
- Set `FEEDBACK_REPO` to the GitHub owner and repository that should receive feedback.
- Store `GITHUB_TOKEN` with Wrangler's secret command. Use a fine-grained token with Issues read/write access to that repository.

Initialize D1 with `schema.sql`; existing deployments apply the files in `migrations/` in order. Then deploy from this directory:

```sh
../../website/node_modules/.bin/wrangler d1 execute yingxia-reports --remote --file schema.sql
../../website/node_modules/.bin/wrangler secret put GITHUB_TOKEN
../../website/node_modules/.bin/wrangler deploy
```

A separately hosted service requires the app's reporting endpoint and privacy policy to use your deployment. Keep credentials in Worker secrets or an ignored `.dev.vars` file.

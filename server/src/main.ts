import { createServer } from "node:http";
import { createHandler, HereNowServer } from "./app.ts";

const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? "0.0.0.0";
const app = new HereNowServer({ dataDir: process.env.HERE_NOW_DATA_DIR ?? "./data" });
const server = createServer(createHandler(app));
server.requestTimeout = 60_000;
server.listen(port, host, () => console.log(`here-now sync server listening on ${host}:${port}`));

// Long-poll requests would otherwise hold shutdown open for up to 25 seconds.
const shutdown = () => {
  server.close(() => process.exit(0));
  app.close();
  server.closeAllConnections();
};
process.on("SIGTERM", shutdown);
process.on("SIGINT", shutdown);

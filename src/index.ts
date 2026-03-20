import { Env } from "./types";
import { handleEmail } from "./email-handler";
import { handleFetch } from "./api";

export default {
  async email(message: ForwardableEmailMessage, env: Env, ctx: ExecutionContext) {
    await handleEmail(message, env, ctx);
  },

  async fetch(request: Request, env: Env, ctx: ExecutionContext) {
    return handleFetch(request, env, ctx);
  },
};

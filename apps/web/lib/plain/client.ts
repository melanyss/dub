import { PlainClient } from "@team-plain/typescript-sdk";

let _plain: PlainClient;
export const plain = new Proxy({} as PlainClient, {
  get(_, prop) {
    if (!_plain) {
      _plain = new PlainClient({
        apiKey: process.env.PLAIN_API_KEY as string,
      });
    }
    return (_plain as any)[prop];
  },
});

export type PlainUser = {
  id: string;
  name: string | null;
  email: string | null;
};

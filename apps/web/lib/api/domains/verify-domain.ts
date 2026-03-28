export const verifyDomain = async (domain: string) => {
  if (!process.env.PROJECT_ID_VERCEL) {
    return { verified: true };
  }
  return await fetch(
    `https://api.vercel.com/v9/projects/${process.env.PROJECT_ID_VERCEL}/domains/${domain.toLowerCase()}/verify?teamId=${process.env.TEAM_ID_VERCEL}`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${process.env.AUTH_BEARER_TOKEN}`,
        "Content-Type": "application/json",
      },
    },
  ).then((res) => res.json());
};

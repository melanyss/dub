import { prisma } from "@dub/prisma";
import { cache } from "react";

export const getProgramSlugs = cache(async () => {
  try {
    return await prisma.program.findMany({
      select: {
        slug: true,
      },
    });
  } catch {
    return [];
  }
});

import type { FastifyReply } from 'fastify';

/// Every error goes out as `{error}`; the till and the site show the text as it is.
export const fail = (reply: FastifyReply, status: number, error: string) =>
  reply.code(status).send({ error });

export const USERNAME = /^[a-z0-9][a-z0-9._-]{2,31}$/;
export const USERNAME_RULE =
  'username: 3 to 32 characters, English letters, digits, dot, dash or underscore';

export class ApiError extends Error {
  constructor(message: string, public code: string, public status: number) { super(message); }
}
export async function api<T>(path: string, options: RequestInit = {}): Promise<T> {
  const headers = new Headers(options.headers);
  if (options.body && typeof options.body === 'string') headers.set('Content-Type', 'application/json');
  const response = await fetch(`/api${path}`, { ...options, headers });
  if (!response.ok) {
    const data = await response.json().catch(() => ({ error: '小屋暂时没有连上，请稍后再试。', code: 'network' }));
    throw new ApiError(data.error, data.code, response.status);
  }
  return response.json();
}
export const body = (value: unknown) => JSON.stringify(value);

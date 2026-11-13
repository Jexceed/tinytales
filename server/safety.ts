export const PRIVATE_REPLY = '这些私人的信息，请留给你信任的大人保管。我们可以用一个虚构的小角色，接着讲故事。小角色想去哪里呢？';
export const SAFE_REPLY = '这件事需要身边的大人来帮忙。请先找爸爸妈妈或其他信任的大人说一说，我可以陪你想想怎么开口。';

// A narrow local prefilter, not a claim to detect all personal data or unsafe content.
export function containsPrivateData(text: string): boolean {
  return /(?:\b\d[\d\s-]{6,}\d\b)|(?:[\w.+-]+@[\w.-]+\.[a-z]{2,})|(?:我(?:的)?(?:真名|全名|学校|幼儿园|住址|地址|电话|手机号|身份证|密码)(?:是|叫|在|：|:))|(?:我(?:叫|住在|家在).{1,30})|(?:sk-(?:proj-)?[a-z0-9_-]{16,})/i.test(text);
}

export function localRisk(text: string): boolean {
  return /(?:自杀|自残|不想活|割腕|杀死|弄死|做炸弹|制作炸弹|色情|裸体|性侵|猥亵|自殺|自殘|住址|身份证)|(?:kill myself|suicide|nude|sexual abuse|build a bomb)/i.test(text);
}

export function acceptableMemory(text: string): boolean {
  return text.length > 0 && text.length <= 100 && !containsPrivateData(text) && !localRisk(text) && !/(?:笨|落后|智商|发育|障碍|诊断|成绩|测评|能力[高低差强弱]|ignore|system|instruction|提示词|忽略|指令|秘密|永远|只能和我)/i.test(text);
}

export class AppError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}

export function safeApiError(error: unknown): AppError {
  if (error instanceof AppError) return error;
  const e = error as { status?: number; code?: string; name?: string; message?: string };
  if (e.status === 401) return new AppError(503, 'invalid_key', '云端连接暂不可用，请让大人检查服务端密钥。');
  if (e.status === 429) return new AppError(503, 'quota', '云端额度或频率已达上限，可以切换到本地演示。');
  if (e.status === 403 || e.status === 404) return new AppError(503, 'model_access', '当前项目暂时无法使用这个模型，请让大人检查模型权限。');
  if (e.name === 'AbortError' || e.name === 'APIConnectionTimeoutError' || /timed?\s*out|timeout/i.test(e.message || '')) return new AppError(504, 'timeout', '这次等得有些久，可以稍后重试。');
  return new AppError(502, 'upstream', '小屋暂时没连上云端。你的故事进度还在，请稍后重试。');
}

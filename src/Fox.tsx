export function Fox({ className = '', small = false }: { className?: string; small?: boolean }) {
  return <svg className={className} viewBox={small ? '30 5 180 180' : '0 0 260 220'} fill="none" aria-hidden="true">
    {!small && <><ellipse cx="132" cy="204" rx="85" ry="9" fill="#dce5d5"/><path d="M204 176c45-1 46-55 23-60-10 38-47 11-51 43" fill="#d59969"/><path d="M219 135c11 1 14-7 14-17 17 6 18 26 9 37" fill="#fff6e7"/><path d="M102 151c-22 10-26 33-16 48h84c8-28-4-42-23-48" fill="#c98457"/><path d="M108 150c-3 19 0 33 19 39 19-4 21-17 19-38" fill="#fff7e8"/><path d="M70 184l54 12 12-36-54-12z" fill="#8d9e7a" stroke="#65785d" strokeWidth="2"/><path d="M136 160l47-14 12 36-60 14z" fill="#e9eddf" stroke="#65785d" strokeWidth="2"/><path d="M136 161l-5 33" stroke="#65785d" strokeWidth="2"/><path d="M87 161l23 7m-25 2l19 6m49-8l20-7m-18 14l19-6" stroke="#a9b696" strokeWidth="2" strokeLinecap="round"/></>}
    <path d="M62 69L66 14c1-5 4-7 8-3l39 35m66 23l-5-55c-1-5-4-7-8-3l-39 35" fill="#d89766" stroke="#bd7c50" strokeWidth="2.5" strokeLinejoin="round"/>
    <path d="M72 48l2-20 20 24m71-4l-2-20-20 24" fill="#6c5e51"/>
    <path d="M58 70c10-27 38-35 62-35s52 8 62 35l12 34c-9 38-41 57-74 57s-65-19-74-57z" fill="#d89766"/>
    <path d="M46 99c15-10 33-8 47 4l27 27 27-27c14-12 32-14 47-4-9 41-41 62-74 62S55 140 46 99" fill="#fff8ec"/>
    <path d="M76 95c5-5 11-5 16 0m56 0c5-5 11-5 16 0" stroke="#4b4c40" strokeWidth="3.5" strokeLinecap="round"/>
    <ellipse cx="72" cy="111" rx="9" ry="5" fill="#e9b09a"/><ellipse cx="168" cy="111" rx="9" ry="5" fill="#e9b09a"/>
    <path d="M113 123q7-5 14 0-2 9-7 9t-7-9" fill="#4b4c40"/><path d="M120 131v6m-8 1q8 7 16 0" stroke="#4b4c40" strokeWidth="2.5" strokeLinecap="round"/>
    {!small && <><path d="M28 143v-14m-7 7h14m184-67V55m-7 7h14" stroke="#a7b58b" strokeWidth="2" strokeLinecap="round"/><path d="M30 182c-14-14-12-24-3-28 9 7 12 17 3 28z" fill="#bbc7a5"/><path d="M227 183c-3-18 3-28 12-26 4 12-2 21-12 26z" fill="#a1b391"/><circle cx="37" cy="82" r="3" fill="#dfc897"/><circle cx="202" cy="100" r="2" fill="#dfc897"/></>}
  </svg>;
}

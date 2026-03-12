import { Outlet, useLocation, useNavigate } from 'react-router-dom'
import { useAuthStore } from '../stores/auth-store'

const NAV_ITEMS = [
  {
    key: 'workbench',
    label: '工作台',
    path: '/',
    match: (p: string) => p === '/' || p.startsWith('/drama/'),
    icon: (
      <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
        <path strokeLinecap="round" strokeLinejoin="round" d="m2.25 12 8.954-8.955c.44-.439 1.152-.439 1.591 0L21.75 12M4.5 9.75v10.125c0 .621.504 1.125 1.125 1.125H9.75v-4.875c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125V21h4.125c.621 0 1.125-.504 1.125-1.125V9.75M8.25 21h8.25" />
      </svg>
    ),
  },
  {
    key: 'voices',
    label: '音色库',
    path: '/voices',
    match: (p: string) => p.startsWith('/casting/') || p.startsWith('/voices'),
    icon: (
      <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M19.114 5.636a9 9 0 0 1 0 12.728M16.463 8.288a5.25 5.25 0 0 1 0 7.424M6.75 8.25l4.72-4.72a.75.75 0 0 1 1.28.53v15.88a.75.75 0 0 1-1.28.53l-4.72-4.72H4.51c-.88 0-1.704-.507-1.938-1.354A9.009 9.009 0 0 1 2.25 12c0-.83.112-1.633.322-2.396C2.806 8.756 3.63 8.25 4.51 8.25H6.75Z" />
      </svg>
    ),
  },
  {
    key: 'glossary',
    label: '术语表',
    path: '/glossary',
    match: (p: string) => p.startsWith('/glossary'),
    icon: (
      <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
        <path strokeLinecap="round" strokeLinejoin="round" d="M12 6.042A8.967 8.967 0 0 0 6 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 0 1 6 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 0 1 6-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0 0 18 18a8.967 8.967 0 0 0-6 2.292m0-14.25v14.25" />
      </svg>
    ),
  },
]

export function AppShell() {
  const location = useLocation()
  const navigate = useNavigate()
  const { user, logout } = useAuthStore()
  const isIDE = location.pathname.startsWith('/ide/')
  const sidebarW = isIDE ? 'w-12' : 'w-16'

  return (
    <div className="h-screen flex bg-[#0a0b10] text-gray-100 overflow-hidden">
      {/* ── Sidebar ── */}
      <aside className={`${sidebarW} shrink-0 flex flex-col border-r border-white/[0.06] bg-[#0c0d12] transition-all duration-200`}>
        {/* Logo */}
        <div className="flex flex-col items-center pt-4 pb-5">
          <img src="/logo.png" alt="Dubora" className="w-7 h-7 rounded-lg" />
          {!isIDE && (
            <span className="text-[9px] font-semibold text-gray-500 mt-1.5 tracking-tight">Dubora</span>
          )}
        </div>

        {/* Nav items */}
        <nav className="flex-1 flex flex-col items-center gap-1 px-1">
          {NAV_ITEMS.map(item => {
            const active = item.match(location.pathname)
            return (
              <button
                key={item.key}
                onClick={() => navigate(item.path)}
                className={`relative w-full flex flex-col items-center py-2 rounded-lg transition-colors ${
                  active
                    ? 'text-blue-400 bg-blue-500/[0.08]'
                    : 'text-gray-600 hover:text-gray-400 hover:bg-white/[0.03]'
                }`}
              >
                {active && (
                  <div className="absolute left-0 top-1/2 -translate-y-1/2 w-[2px] h-4 rounded-r bg-blue-400" />
                )}
                {item.icon}
                {!isIDE && (
                  <span className="text-[9px] mt-1">{item.label}</span>
                )}
              </button>
            )
          })}
        </nav>

        {/* User + Logout at bottom */}
        <div className="flex flex-col items-center pb-4 px-1 gap-1">
          {user?.picture ? (
            <img
              src={user.picture}
              alt={user.name}
              title={user.email}
              className="w-7 h-7 rounded-full"
              referrerPolicy="no-referrer"
            />
          ) : (
            <div
              title={user?.email}
              className="w-7 h-7 rounded-full bg-gray-700 flex items-center justify-center text-[10px] font-bold text-gray-300"
            >
              {user?.name?.[0]?.toUpperCase() ?? '?'}
            </div>
          )}
          <button
            onClick={logout}
            title="Logout"
            className="w-full flex flex-col items-center py-2 rounded-lg text-gray-600 hover:text-gray-400 hover:bg-white/[0.03] transition-colors"
          >
            <svg className="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth={1.5}>
              <path strokeLinecap="round" strokeLinejoin="round" d="M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3h-6a2.25 2.25 0 0 0-2.25 2.25v13.5A2.25 2.25 0 0 0 7.5 21h6a2.25 2.25 0 0 0 2.25-2.25V15m3 0 3-3m0 0-3-3m3 3H9" />
            </svg>
            {!isIDE && (
              <span className="text-[9px] mt-1">Logout</span>
            )}
          </button>
        </div>
      </aside>

      {/* ── Main content ── */}
      <div className="flex-1 min-w-0 overflow-auto">
        <Outlet />
      </div>
    </div>
  )
}

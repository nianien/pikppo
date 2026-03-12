import { useState, useEffect } from "react";

const GoogleIcon = () => (
  <svg width="18" height="18" viewBox="0 0 24 24">
    <path d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" fill="#4285F4"/>
    <path d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" fill="#34A853"/>
    <path d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" fill="#FBBC05"/>
    <path d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" fill="#EA4335"/>
  </svg>
);

const STEPS = [
  { label: "上传视频", icon: "M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5m-13.5-9L12 3m0 0l4.5 4.5M12 3v13.5" },
  { label: "智能翻译", icon: "M10.5 21l5.25-11.25L21 21m-9-3h7.5M3 5.621a48.474 48.474 0 016-.371m0 0c1.12 0 2.233.038 3.334.114M9 5.25V3m3.334 2.364C11.176 10.658 7.69 15.08 3 17.502m9.334-12.138c.896.061 1.785.147 2.666.257m-4.589 8.495a18.023 18.023 0 01-3.827-5.802" },
  { label: "多角色配音", icon: "M19.114 5.636a9 9 0 010 12.728M16.463 8.288a5.25 5.25 0 010 7.424M6.75 8.25l4.72-4.72a.75.75 0 011.28.53v15.88a.75.75 0 01-1.28.53l-4.72-4.72H4.51c-.88 0-1.704-.507-1.938-1.354A9.009 9.009 0 012.25 12c0-.83.112-1.633.322-2.396C2.806 8.756 3.63 8.25 4.51 8.25H6.75z" },
  { label: "导出成片", icon: "M3 16.5v2.25A2.25 2.25 0 005.25 21h13.5A2.25 2.25 0 0021 18.75V16.5M16.5 12L12 16.5m0 0L7.5 12m4.5 4.5V3" },
];

const FEATURES = [
  { icon: "M19.114 5.636a9 9 0 010 12.728M16.463 8.288a5.25 5.25 0 010 7.424M6.75 8.25l4.72-4.72a.75.75 0 011.28.53v15.88a.75.75 0 01-1.28.53l-4.72-4.72H4.51c-.88 0-1.704-.507-1.938-1.354A9.009 9.009 0 012.25 12c0-.83.112-1.633.322-2.396C2.806 8.756 3.63 8.25 4.51 8.25H6.75z", title: "多角色声线", desc: "预设声线池，按角色自动分配独立音色", color: "#818cf8" },
  { icon: "M9 12.75L11.25 15 15 9.75m-3-7.036A11.959 11.959 0 013.598 6 11.99 11.99 0 003 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285z", title: "质量门控", desc: "翻译和配音后各设审核节点，精准把控质量", color: "#34d399" },
  { icon: "M16.023 9.348h4.992v-.001M2.985 19.644v-4.992m0 0h4.992m-4.993 0l3.181 3.183a8.25 8.25 0 0013.803-3.7M4.031 9.865a8.25 8.25 0 0113.803-3.7l3.181 3.182M21.015 4.356v4.992", title: "增量重跑", desc: "仅处理改动部分，节省 API 费用和时间", color: "#fbbf24" },
  { icon: "M6 6.878V6a2.25 2.25 0 012.25-2.25h7.5A2.25 2.25 0 0118 6v.878m-12 0c.235-.083.487-.128.75-.128h10.5c.263 0 .515.045.75.128m-12 0A2.25 2.25 0 004.5 9v.878m13.5-3A2.25 2.25 0 0119.5 9v.878m0 0a2.246 2.246 0 00-.75-.128H5.25c-.263 0-.515.045-.75.128m15 0A2.25 2.25 0 0121 12v6a2.25 2.25 0 01-2.25 2.25H5.25A2.25 2.25 0 013 18v-6c0-1.007.66-1.862 1.572-2.148", title: "批量处理", desc: "多集并行投递，全自动排队执行", color: "#f472b6" },
];

export function LandingPage() {
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  return (
    <div style={{
      minHeight: "100vh",
      background: "#06060b",
      color: "#e8e6e0",
      fontFamily: "'DM Sans', -apple-system, sans-serif",
      overflow: "hidden",
      position: "relative",
    }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=DM+Sans:wght@300;400;500;600&family=Playfair+Display:ital,wght@0,700;1,400&display=swap');

        .lp-fade { opacity: 0; transform: translateY(30px); transition: opacity 1s cubic-bezier(0.16,1,0.3,1), transform 1s cubic-bezier(0.16,1,0.3,1); }
        .lp-fade.show { opacity: 1; transform: translateY(0); }
        .lp-d1 { transition-delay: 0.1s; }
        .lp-d2 { transition-delay: 0.2s; }
        .lp-d3 { transition-delay: 0.35s; }
        .lp-d4 { transition-delay: 0.5s; }
        .lp-d5 { transition-delay: 0.65s; }

        .lp-orb {
          position: absolute;
          border-radius: 50%;
          filter: blur(140px);
          pointer-events: none;
          animation: lp-float 12s ease-in-out infinite alternate;
        }
        @keyframes lp-float {
          0% { transform: translate(0, 0) scale(1); }
          100% { transform: translate(30px, -20px) scale(1.1); }
        }

        .lp-cta {
          display: inline-flex;
          align-items: center;
          gap: 12px;
          padding: 16px 36px;
          background: rgba(99,102,241,0.15);
          color: #fff;
          border: 1px solid rgba(99,102,241,0.35);
          border-radius: 12px;
          font-size: 16px;
          font-weight: 500;
          cursor: pointer;
          transition: all 0.25s ease;
          font-family: 'DM Sans', sans-serif;
          text-decoration: none;
          backdrop-filter: blur(12px);
        }
        .lp-cta:hover {
          background: rgba(99,102,241,0.25);
          border-color: rgba(99,102,241,0.5);
          transform: translateY(-2px);
          box-shadow: 0 12px 40px rgba(99,102,241,0.2);
        }

        .lp-feature {
          background: rgba(255,255,255,0.03);
          border: 1px solid rgba(255,255,255,0.06);
          border-radius: 16px;
          padding: 32px;
          transition: all 0.3s ease;
          text-align: left;
        }
        .lp-feature:hover {
          background: rgba(255,255,255,0.05);
          border-color: rgba(255,255,255,0.12);
          transform: translateY(-2px);
        }

        .lp-step {
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 12px;
          flex: 1;
          min-width: 0;
        }
        .lp-step-icon {
          width: 52px; height: 52px;
          border-radius: 14px;
          display: flex;
          align-items: center;
          justify-content: center;
          background: rgba(99,102,241,0.1);
          border: 1px solid rgba(99,102,241,0.2);
          transition: all 0.3s ease;
        }
        .lp-step:hover .lp-step-icon {
          background: rgba(99,102,241,0.18);
          border-color: rgba(99,102,241,0.4);
          transform: scale(1.08);
        }
        .lp-connector {
          width: 40px;
          height: 1px;
          background: linear-gradient(90deg, rgba(99,102,241,0.3), rgba(99,102,241,0.08));
          margin-top: 26px;
          flex-shrink: 0;
        }

        .lp-stat {
          text-align: center;
          padding: 32px 20px;
        }
        .lp-stat-num {
          font-family: 'Playfair Display', serif;
          font-size: 44px;
          font-weight: 700;
          letter-spacing: -0.03em;
          line-height: 1;
          background: linear-gradient(135deg, #fff 30%, rgba(255,255,255,0.5));
          -webkit-background-clip: text;
          -webkit-text-fill-color: transparent;
          background-clip: text;
        }

        .lp-grid-line {
          position: absolute;
          background: rgba(99,102,241,0.05);
          pointer-events: none;
        }
      `}</style>

      {/* Ambient background */}
      <div className="lp-orb" style={{ width: 700, height: 700, background: "rgba(99,102,241,0.10)", top: -250, right: -150 }} />
      <div className="lp-orb" style={{ width: 500, height: 500, background: "rgba(139,92,246,0.08)", top: "40%", left: -200, animationDelay: "4s" }} />
      <div className="lp-orb" style={{ width: 400, height: 400, background: "rgba(16,185,129,0.06)", bottom: -100, right: "20%", animationDelay: "8s" }} />

      {/* Subtle grid lines */}
      <div className="lp-grid-line" style={{ width: 1, height: "100%", left: "25%", top: 0 }} />
      <div className="lp-grid-line" style={{ width: 1, height: "100%", left: "50%", top: 0 }} />
      <div className="lp-grid-line" style={{ width: 1, height: "100%", left: "75%", top: 0 }} />

      {/* Nav */}
      <nav style={{ padding: "28px 56px", display: "flex", alignItems: "center", position: "relative", zIndex: 10 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
          <img src="/logo.png" alt="Dubora" style={{ width: 36, height: 36, borderRadius: 8 }} />
          <div>
            <div style={{ fontSize: 19, fontWeight: 600, letterSpacing: "-0.03em", lineHeight: 1.2 }}>Dubora</div>
            <div style={{ fontSize: 10, color: "rgba(255,255,255,0.3)", letterSpacing: "0.04em" }}>AI 短剧配音平台</div>
          </div>
        </div>
      </nav>

      {/* Hero */}
      <main style={{ maxWidth: 1200, margin: "0 auto", padding: "60px 56px 80px", position: "relative", zIndex: 10, textAlign: "center" }}>

        {/* Title */}
        <h1 className={`lp-fade lp-d1 ${mounted ? "show" : ""}`} style={{
          fontSize: "clamp(44px, 6.5vw, 76px)",
          fontFamily: "'Playfair Display', serif",
          fontWeight: 700, lineHeight: 1.08,
          letterSpacing: "-0.03em", marginBottom: 28,
          maxWidth: 900, margin: "0 auto 28px",
        }}>
          中文短剧出海<br />
          <span style={{
            background: "linear-gradient(135deg, rgba(255,255,255,0.45), rgba(165,180,252,0.6))",
            WebkitBackgroundClip: "text", WebkitTextFillColor: "transparent", backgroundClip: "text",
            fontStyle: "italic",
          }}>AI 全流程英文配音</span>
        </h1>

        {/* Subtitle */}
        <p className={`lp-fade lp-d2 ${mounted ? "show" : ""}`} style={{
          fontSize: 18, lineHeight: 1.8,
          color: "rgba(255,255,255,0.4)",
          maxWidth: 540, margin: "0 auto 48px",
        }}>
          从语音识别到字幕烧录，自动交付可发布的英文配音版
        </p>

        {/* CTA */}
        <div className={`lp-fade lp-d3 ${mounted ? "show" : ""}`} style={{ marginBottom: 80 }}>
          <a className="lp-cta" href="/api/auth/google/login">
            <GoogleIcon />
            使用 Google 账号开始
          </a>
          <p style={{ marginTop: 16, fontSize: 12, color: "rgba(255,255,255,0.2)", letterSpacing: "0.02em" }}>仅限受邀用户</p>
        </div>

        {/* Pipeline */}
        <div className={`lp-fade lp-d4 ${mounted ? "show" : ""}`} style={{
          display: "flex", alignItems: "flex-start", justifyContent: "center",
          gap: 0, marginBottom: 80, padding: "0 40px",
          maxWidth: 700, margin: "0 auto 80px",
        }}>
          {STEPS.map((step, i) => (
            <div key={step.label} style={{ display: "flex", alignItems: "flex-start" }}>
              <div className="lp-step">
                <div className="lp-step-icon">
                  <svg width="22" height="22" fill="none" viewBox="0 0 24 24" stroke="#818cf8" strokeWidth={1.5}>
                    <path strokeLinecap="round" strokeLinejoin="round" d={step.icon} />
                  </svg>
                </div>
                <span style={{ fontSize: 13, color: "rgba(255,255,255,0.5)", fontWeight: 500 }}>{step.label}</span>
              </div>
              {i < STEPS.length - 1 && <div className="lp-connector" />}
            </div>
          ))}
        </div>

        {/* Divider */}
        <div className={`lp-fade lp-d4 ${mounted ? "show" : ""}`} style={{
          width: 48, height: 1,
          background: "linear-gradient(90deg, transparent, rgba(99,102,241,0.3), transparent)",
          margin: "0 auto 80px",
        }} />

        {/* Stats */}
        <div className={`lp-fade lp-d5 ${mounted ? "show" : ""}`} style={{
          display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 0,
          background: "rgba(255,255,255,0.02)",
          borderRadius: 20, overflow: "hidden",
          border: "1px solid rgba(255,255,255,0.06)",
        }}>
          {[
            { num: "2-5", label: "分钟/集", sub: "平均处理时长" },
            { num: "20+", label: "AI 声线", sub: "按角色自动分配" },
            { num: "100+", label: "集/天", sub: "批量并行投递" },
          ].map(({ num, label, sub }, i) => (
            <div key={label} className="lp-stat" style={{
              borderRight: i < 2 ? "1px solid rgba(255,255,255,0.06)" : "none",
            }}>
              <div className="lp-stat-num">{num}</div>
              <div style={{ marginTop: 10, fontSize: 14, color: "rgba(255,255,255,0.6)", fontWeight: 500 }}>{label}</div>
              <div style={{ marginTop: 4, fontSize: 11, color: "rgba(255,255,255,0.25)" }}>{sub}</div>
            </div>
          ))}
        </div>

        {/* Features */}
        <div style={{ display: "grid", gridTemplateColumns: "repeat(4, 1fr)", gap: 14, marginTop: 14 }}>
          {FEATURES.map(({ icon, title, desc, color }) => (
            <div key={title} className="lp-feature">
              <div style={{
                width: 40, height: 40, borderRadius: 12, marginBottom: 16,
                background: `${color}10`, border: `1px solid ${color}25`,
                display: "flex", alignItems: "center", justifyContent: "center",
              }}>
                <svg width="20" height="20" fill="none" viewBox="0 0 24 24" stroke={color} strokeWidth={1.5}>
                  <path strokeLinecap="round" strokeLinejoin="round" d={icon} />
                </svg>
              </div>
              <div style={{ fontSize: 15, fontWeight: 600, marginBottom: 8, color: "rgba(255,255,255,0.85)" }}>{title}</div>
              <div style={{ fontSize: 13, color: "rgba(255,255,255,0.35)", lineHeight: 1.7 }}>{desc}</div>
            </div>
          ))}
        </div>
      </main>

      {/* Footer */}
      <footer style={{
        textAlign: "center", padding: "48px",
        color: "rgba(255,255,255,0.15)", fontSize: 12,
        position: "relative", zIndex: 10,
        letterSpacing: "0.03em",
      }}>
        &copy; {new Date().getFullYear()} Dubora by Pikppo
      </footer>
    </div>
  );
}

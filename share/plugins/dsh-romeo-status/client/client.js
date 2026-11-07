// dsh-romeo-status, the client side: a small badge beside dsh's input box (the slot
// conversation.input.right, on the welcome page and in a session) with what needs you about the
// model jobs on ROMEO. Asks the host side (GET ./dsh-romeo-status) every 30 s while the window is
// visible; shows nothing when all is well.
window.__ModuleLoader__.load({
  id: "dsh-romeo-status",
  factory: (require) => {
    var React = require("react");
    var h = React.createElement;
    var COLORS = { info: "#3b82f6", warn: "#d97706", error: "#dc2626" };
    var EVERY = 30000;

    function useStatus() {
      var state = React.useState([]);
      var items = state[0], setItems = state[1];
      React.useEffect(function () {
        var alive = true, timer = null;
        function ask() {
          if (document.visibilityState === "hidden") { timer = setTimeout(ask, EVERY); return; }
          fetch("./dsh-romeo-status", { cache: "no-store", headers: { "x-dsh-locale": document.documentElement.lang || "en" } })
            .then(function (r) { return r.ok ? r.json() : { items: [] }; })
            .catch(function () { return { items: [] }; })
            .then(function (v) {
              if (!alive) return;
              var next = Array.isArray(v && v.items) ? v.items : [];
              setItems(function (prev) { return JSON.stringify(prev) === JSON.stringify(next) ? prev : next; });
              timer = setTimeout(ask, EVERY);
            });
        }
        ask();
        function onVisible() { if (document.visibilityState === "visible") { clearTimeout(timer); ask(); } }
        document.addEventListener("visibilitychange", onVisible);
        return function () { alive = false; clearTimeout(timer); document.removeEventListener("visibilitychange", onVisible); };
      }, []);
      return items;
    }

    function Badge() {
      var items = useStatus();
      if (!items.length) return null;
      var first = items[0];
      var worst = items.some(function (i) { return i.level === "error"; }) ? "error" : items.some(function (i) { return i.level === "warn"; }) ? "warn" : "info";
      return h("span", {
        title: items.map(function (i) { return i.text; }).join("\n"),
        style: {
          display: "inline-flex", alignItems: "center", gap: 6, maxWidth: 420, height: 24, padding: "0 8px",
          borderRadius: 12, fontSize: 12, lineHeight: "24px", whiteSpace: "nowrap", overflow: "hidden",
          color: "inherit", opacity: 0.85, background: "color-mix(in srgb, " + COLORS[worst] + " 12%, transparent)",
          border: "1px solid color-mix(in srgb, " + COLORS[worst] + " 35%, transparent)", verticalAlign: "middle",
        },
      },
        h("span", { style: { width: 7, height: 7, borderRadius: "50%", background: COLORS[worst], flex: "none" } }),
        h("span", { style: { overflow: "hidden", textOverflow: "ellipsis" } }, first.text),
        items.length > 1 ? h("span", { style: { opacity: 0.7, flex: "none" } }, "+" + (items.length - 1)) : null
      );
    }

    function apply(ctx) {
      ctx.slots.inject("conversation.input.right", function () {
        return ctx.slots.register({ name: "conversation.input.right", id: "dsh-romeo-status", order: 50 }, Badge);
      });
    }

    var exports = { name: "dsh-romeo-status", inject: ["slots"], apply: apply };
    return exports;
  },
});

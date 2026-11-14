// Every page loads this. If the server says the site is locked (the session ran out, or the server restarted),
// go to the YubiKey page and come back here afterwards. Also adds "Lock" to the menu.
(function () {
  var real = window.fetch;
  window.fetch = async function () {
    var r = await real.apply(this, arguments);
    if (r.status === 401) {
      try { var d = await r.clone().json(); if (d && d.locked) location.href = "/gate?next=" + encodeURIComponent(location.pathname); } catch (e) {}
    }
    return r;
  };
  document.addEventListener("DOMContentLoaded", function () {
    var nav = document.querySelector("header nav"); if (!nav) return;
    var a = document.createElement("a"); a.href = "/gate"; a.textContent = "Lock"; a.title = "Lock Heimdall in this browser";
    a.onclick = async function (e) { e.preventDefault(); try { await real("api/gate/lock", { method: "POST", body: "{}" }); } catch (x) {} location.href = "/gate"; };
    nav.appendChild(a);
  });
})();

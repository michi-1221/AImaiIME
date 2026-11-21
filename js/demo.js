(function () {
  // BRIEF.md の「使ってよい例文」から。[] は打ち間違い、_ は1文字抜けの位置。
  var SAMPLES = [
    ["ekim[s]enoka[f]fed_matteirunodetsuitararenrakushitekudasai", "駅前のカフェで待っているので着いたら連絡してください"],
    ["d[w]nshagaoku[t]reteirunodejuppunnkuraiosokunarimas_", "電車が遅れているので10分くらい遅くなります"],
    ["kasawomott[w]inainodeekimad[w]mukaenikitehoshii", "傘を持っていないので駅まで迎えに来てほしい"],
    ["sukosiok_remasugasakinihajim[w]teitekudasai", "少し遅れますが先に始めていてください"]
  ];

  var ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"];
  var $ = function (id) { return document.getElementById(id); };
  var lineEl = $("line"), kbd = $("kbd");
  var keys = {};

  ROWS.forEach(function (r, i) {
    var row = document.createElement("div");
    row.className = "row r" + (i + 1);
    r.split("").forEach(function (c) {
      var k = document.createElement("span");
      k.className = "key"; k.textContent = c; keys[c] = k; row.appendChild(k);
    });
    kbd.appendChild(row);
  });
  var sp = document.createElement("div");
  sp.className = "row";
  var spk = document.createElement("span");
  spk.className = "key space"; spk.textContent = "Space";
  sp.appendChild(spk); kbd.appendChild(sp);

  // 戻り値: c=文字、e=打ち間違い、gap=抜けた位置（空白1文字分に赤い下線）
  function parse(s) {
    var out = [], i = 0;
    while (i < s.length) {
      if (s[i] === "[") {
        var end = s.indexOf("]", i);
        s.slice(i + 1, end).split("").forEach(function (c) { out.push({ c: c, e: true }); });
        i = end + 1;
      } else if (s[i] === "_") { out.push({ gap: true }); i++; }
      else { out.push({ c: s[i] }); i++; }
    }
    return out;
  }
  function node(t) {
    if (t.gap) { var g = document.createElement("span"); g.className = "gap"; g.textContent = "\u00a0"; return g; }
    if (t.e) { var e = document.createElement("span"); e.className = "err"; e.textContent = t.c; return e; }
    return document.createTextNode(t.c);
  }

  // 文を改行させずに1行に収める: 幅を実際に測り、はみ出すときだけ文字を縮める
  function fit(el) {
    el.style.fontSize = "";
    // 中央揃えのままだとはみ出し幅を正しく測れないため、測るあいだだけ左揃えにする
    el.style.textAlign = "left";
    var avail = el.clientWidth, need = el.scrollWidth;
    el.style.textAlign = "";
    if (avail > 0 && need > avail) {
      var size = parseFloat(getComputedStyle(el).fontSize);
      el.style.fontSize = (size * avail / need * 0.98) + "px";
    }
  }

  var reduce = window.matchMedia && matchMedia("(prefers-reduced-motion: reduce)").matches;

  if (reduce) {
    $("demo").querySelector(".line-wrap").hidden = true;
    var ul = document.createElement("ul");
    SAMPLES.forEach(function (s) {
      var li = document.createElement("li");
      var b = document.createElement("p"); b.className = "before";
      parse(s[0]).forEach(function (t) { b.appendChild(node(t)); });
      var a = document.createElement("p"); a.className = "after"; a.textContent = "→ " + s[1];
      li.appendChild(b); li.appendChild(a);
      ul.appendChild(li);
    });
    var st = $("static"); st.appendChild(ul); st.hidden = false;
    // 静的表示: キーボードは飾りとして残し、デモ枠は並べ表示に置き換える
    $("demo").replaceChildren(st);
    st.hidden = false;
    var fitAll = function () { st.querySelectorAll(".before, .after").forEach(fit); };
    fitAll();
    if (document.fonts && document.fonts.ready) document.fonts.ready.then(fitAll);
    window.addEventListener("resize", fitAll);
    return;
  }

  var wait = function (ms) { return new Promise(function (r) { setTimeout(r, ms); }); };
  function flash(el, cls, ms) {
    el.classList.add(cls);
    return wait(ms).then(function () { el.classList.remove(cls); });
  }

  async function play(sample) {
    var toks = parse(sample[0]);
    lineEl.className = "line";
    // 打ち終わりの幅で文字の大きさを決め、打っている途中で大きさが変わらないようにする
    lineEl.replaceChildren.apply(lineEl, toks.map(node));
    fit(lineEl);
    var typedSize = lineEl.style.fontSize;
    lineEl.textContent = "";
    lineEl.style.fontSize = typedSize;
    var cursor = document.createElement("span"); cursor.className = "cursor";
    lineEl.appendChild(cursor);
    await wait(350);
    for (var i = 0; i < toks.length; i++) {
      var t = toks[i], bad = !!t.e;
      lineEl.insertBefore(node(t), cursor);
      var k = t.c && keys[t.c];
      if (k) flash(k, bad ? "bad" : "on", bad ? 200 : 80);
      await wait(bad || t.gap ? 200 : 50 + Math.random() * 25);
    }
    await wait(550);
    await flash(spk, "on", 350);
    lineEl.className = "line jp";
    lineEl.textContent = sample[1];
    fit(lineEl);
    await wait(2600);
  }

  (async function loop() {
    var i = 0;
    while (true) { await play(SAMPLES[i % SAMPLES.length]); i++; }
  })();
})();

(function () {
  document.querySelectorAll(".copy").forEach(function (b) {
    b.addEventListener("click", function () {
      var text = document.getElementById(b.dataset.target).textContent;
      var ok = function () {
        b.textContent = "コピーしました"; b.classList.add("done");
        setTimeout(function () { b.textContent = "コピー"; b.classList.remove("done"); }, 1800);
      };
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(ok, function () {});
      } else {
        var t = document.createElement("textarea"); t.value = text; document.body.appendChild(t);
        t.select(); try { document.execCommand("copy"); ok(); } catch (e) {} t.remove();
      }
    });
  });
})();

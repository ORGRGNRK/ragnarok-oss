"""The one page this program serves. No external assets."""

PAGE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'">
<title>Answer engine</title>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0 auto;
    max-width: 40rem;
    padding: 1rem;
    font-family: system-ui, sans-serif;
    line-height: 1.45;
    background: #f6f5f2;
    color: #1b1b1b;
  }
  h1 { font-size: 1.35rem; font-weight: 650; margin: 0 0 0.25rem; }
  h2 { font-size: 1.05rem; margin: 1.4rem 0 0.4rem; }
  p { margin: 0.4rem 0; }
  label { display: block; margin-bottom: 0.25rem; }
  textarea, input, button {
    font: inherit;
    font-size: 1rem;
    width: 100%;
  }
  textarea, input {
    padding: 0.5rem;
    border: 1px solid #b7b3aa;
    border-radius: 0.35rem;
    background: #fff;
    color: inherit;
  }
  textarea { min-height: 7rem; resize: vertical; }
  button {
    margin-top: 0.45rem;
    padding: 0.55rem 0.7rem;
    border: 1px solid #8d897f;
    border-radius: 0.35rem;
    background: #efece4;
    color: inherit;
  }
  #status, #answer, #notice, li, button {
    overflow-wrap: anywhere;
  }
  #answer, #notice, li div {
    white-space: pre-wrap;
  }
  details {
    margin-top: 0.8rem;
    border: 1px solid #c8c4ba;
    border-radius: 0.35rem;
    padding: 0.55rem 0.7rem;
  }
  summary { cursor: pointer; }
  #thread .turn { border-left: 3px solid #c8c4ba; padding: 0.2rem 0 0.2rem 0.7rem; margin: 0.6rem 0; white-space: pre-wrap; overflow-wrap: anywhere; }
  #thread .who { font-weight: 650; }
  #grounding { font-weight: 600; color: #a33a1e; }
  #reply-box { margin-top: 1rem; display: none; }
  @media (prefers-color-scheme: dark) { #grounding { color: #ff8a6b; } #thread .turn { border-color: #555; } }
  ol { margin: 0.4rem 0 0; padding-left: 1.2rem; }
  li { margin: 0.45rem 0; }
  @media (prefers-color-scheme: dark) {
    body { background: #141414; color: #f3f1ea; }
    textarea, input { background: #222; border-color: #555; }
    button { background: #2a2a2a; border-color: #777; }
    details { border-color: #555; }
  }
</style>
</head>
<body>
<h1>Answer engine</h1>
<p>Ask a question. The trace shows each tool that actually ran.</p>
<form id="ask">
  <label for="question">Question</label>
  <textarea id="question" maxlength="4000"></textarea>
  <button type="submit">Ask</button>
</form>
<p id="status"></p>
<div id="thread"></div>
<h2>Answer</h2>
<p id="grounding"></p>
<p id="answer"></p>
<form id="reply-box">
  <label for="reply">Reply or add context</label>
  <textarea id="reply" maxlength="4000" placeholder="Ask a follow-up, or add details the answer missed."></textarea>
  <button type="submit">Reply</button>
</form>
<details id="trace">
  <summary>How it got this answer</summary>
  <p id="notice"></p>
  <ol id="steps"></ol>
</details>
<h2>Search past answers</h2>
<form id="search">
  <label for="q">Search</label>
  <input id="q" type="text">
  <button type="submit">Search</button>
</form>
<div id="hits"></div>
<h2>Recent</h2>
<div id="recent"></div>
<script>
function setText(el, value) {
  el.textContent = value == null ? "" : String(value);
}

function thinkingNotice(events) {
  var i, ev;
  for (i = 0; i < events.length; i++) {
    ev = events[i];
    if (ev && ev.type === "thinking" && ev.kind !== "summary" && ev.text) {
      return "";
    }
  }
  return "This AI did not share its thinking";
}

function clearNode(node) {
  while (node.firstChild) {
    node.removeChild(node.firstChild);
  }
}

function renderSteps(events) {
  var list = document.getElementById("steps");
  var i, ev, li, label, head, strong, body;
  clearNode(list);
  for (i = 0; i < events.length; i++) {
    ev = events[i];
    li = document.createElement("li");
    label = ev.type || "step";
    if (ev.type === "thinking" && ev.kind === "summary") {
      label = "Reasoning summary";
    } else if (ev.type === "thinking") {
      label = "Thinking";
    } else if (ev.type === "tool_call") {
      label = "Tool call";
    } else if (ev.type === "tool_result") {
      label = "Tool result";
    } else if (ev.type === "answer") {
      label = ev.interim ? "Interim answer" : "Answer";
    } else if (ev.type === "error") {
      label = "Error";
    } else if (ev.type === "done") {
      label = "Done";
    }
    head = label;
    if (ev.provider) {
      head += " · " + ev.provider;
    }
    if (ev.model) {
      head += " · " + ev.model;
    }
    if (ev.name) {
      head += " · " + ev.name;
    }
    if (ev.duration_ms != null) {
      head += " · " + ev.duration_ms + " ms elapsed";
    }
    strong = document.createElement("strong");
    setText(strong, head);
    li.appendChild(strong);
    if (ev.text) {
      body = document.createElement("div");
      setText(body, ev.text);
      li.appendChild(body);
    }
    list.appendChild(li);
  }
  setText(document.getElementById("notice"), thinkingNotice(events));
}

var trace = [];
var currentId = null;
var currentThread = [];

function groundingNotice(events, finished) {
  var i;
  for (i = 0; i < events.length; i++) {
    if (events[i] && events[i].type === "tool_call") {
      return "";
    }
  }
  return finished ? "No web search was run for this answer. It came from the AI's memory." : "";
}

function renderThread() {
  var box = document.getElementById("thread");
  var i, turn, div, who, text;
  clearNode(box);
  for (i = 0; i < currentThread.length; i++) {
    turn = currentThread[i];
    [["You", turn.question], ["AI", turn.answer]].forEach(function (pair) {
      div = document.createElement("div");
      div.className = "turn";
      who = document.createElement("div");
      who.className = "who";
      setText(who, pair[0]);
      text = document.createElement("div");
      setText(text, pair[1] || "");
      div.appendChild(who);
      div.appendChild(text);
      box.appendChild(div);
    });
  }
}

function showReply(show) {
  document.getElementById("reply-box").style.display = show ? "block" : "none";
}

function applyEvent(ev) {
  trace.push(ev);
  renderSteps(trace);
  if (ev.type === "answer" && !ev.interim) {
    setText(document.getElementById("answer"), ev.text);
  }
  if (ev.type === "error" && ev.text === "This run timed out.") {
    setText(document.getElementById("answer"), ev.text);
  }
  if (ev.type === "done") {
    if (ev.text) {
      setText(document.getElementById("answer"), ev.text);
    }
    setText(document.getElementById("status"), "Done.");
    setText(document.getElementById("grounding"), groundingNotice(trace, true));
    if (ev.question_id != null) {
      currentId = ev.question_id;
      showReply(true);
    }
    loadRecent();
  } else if (ev.type === "tool_call") {
    setText(document.getElementById("status"), "Running a tool");
  } else if (ev.type === "thinking") {
    setText(document.getElementById("status"), "Working.");
  } else if (ev.type === "error") {
    setText(document.getElementById("status"), ev.text);
  }
}

function readStream(response) {
  var reader = response.body.getReader();
  var decoder = new TextDecoder();
  var buf = "";
  function pump() {
    return reader.read().then(function (part) {
      var idx, block, line, ev;
      if (part.done) {
        return;
      }
      buf += decoder.decode(part.value, {stream: true});
      while ((idx = buf.indexOf("\n\n")) >= 0) {
        block = buf.slice(0, idx);
        buf = buf.slice(idx + 2);
        line = block.indexOf("data:") === 0 ? block.slice(5).replace(/^\s/, "") : "";
        if (!line) {
          continue;
        }
        try {
          ev = JSON.parse(line);
        } catch (err) {
          continue;
        }
        applyEvent(ev);
      }
      return pump();
    });
  }
  return pump();
}

function fillButtons(parent, items) {
  var i;
  clearNode(parent);
  for (i = 0; i < items.length; i++) {
    (function (item) {
      var button = document.createElement("button");
      button.type = "button";
      setText(button, item.question || "(empty)");
      button.addEventListener("click", function () {
        openQuestion(item.id);
      });
      parent.appendChild(button);
    })(items[i]);
  }
}

function openQuestion(id) {
  fetch("/api/questions/" + id).then(function (response) {
    return response.json();
  }).then(function (item) {
    var status = item.status || "";
    document.getElementById("question").value = item.question || "";
    setText(document.getElementById("answer"), item.answer || "");
    trace = item.events || [];
    renderSteps(trace);
    currentId = item.id;
    currentThread = item.thread || [];
    renderThread();
    setText(document.getElementById("grounding"), groundingNotice(trace, item.status !== "running"));
    showReply(item.status !== "running");
    if (item.provider) {
      status = item.provider + " · " + status;
    }
    setText(document.getElementById("status"), status);
  }).catch(function () {
    setText(document.getElementById("status"), "Could not open that answer.");
  });
}

function loadRecent() {
  return fetch("/api/recent").then(function (response) {
    return response.json();
  }).then(function (data) {
    fillButtons(document.getElementById("recent"), data.results || []);
  }).catch(function () {
    setText(document.getElementById("status"), "Could not load recent answers.");
  });
}

function send(question, parentId) {
  trace = [];
  renderSteps(trace);
  setText(document.getElementById("answer"), "");
  setText(document.getElementById("grounding"), "");
  setText(document.getElementById("status"), "Working.");
  showReply(false);
  fetch("/api/ask", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({question: question, parent_id: parentId})
  }).then(function (response) {
    if (response.status === 409) {
      setText(document.getElementById("status"), "Busy. One question is already running.");
      return;
    }
    if (!response.ok) {
      return response.text().then(function (text) {
        setText(document.getElementById("status"), text);
      });
    }
    if (!response.body || !response.body.getReader) {
      setText(document.getElementById("status"), "This browser cannot show the live path.");
      return;
    }
    return readStream(response);
  }).catch(function () {
    setText(document.getElementById("status"), "The request failed.");
  });
}

document.getElementById("ask").addEventListener("submit", function (event) {
  event.preventDefault();
  currentThread = [];
  renderThread();
  send(document.getElementById("question").value, null);
});

document.getElementById("reply-box").addEventListener("submit", function (event) {
  var text = document.getElementById("reply").value;
  event.preventDefault();
  if (!text.trim() || currentId == null) {
    return;
  }
  currentThread.push({
    question: document.getElementById("question").value,
    answer: document.getElementById("answer").textContent
  });
  renderThread();
  document.getElementById("question").value = text;
  document.getElementById("reply").value = "";
  send(text, currentId);
});

document.getElementById("search").addEventListener("submit", function (event) {
  var query = document.getElementById("q").value;
  event.preventDefault();
  fetch("/api/search?q=" + encodeURIComponent(query)).then(function (response) {
    return response.json();
  }).then(function (data) {
    var items = data.results || [];
    var empty;
    fillButtons(document.getElementById("hits"), items);
    if (!items.length) {
      empty = document.createElement("p");
      setText(empty, "No matches.");
      document.getElementById("hits").appendChild(empty);
    }
  }).catch(function () {
    setText(document.getElementById("status"), "Search failed.");
  });
});

loadRecent();
</script>
</body>
</html>
"""

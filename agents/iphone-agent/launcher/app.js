const commandList = document.querySelector("#command-list");
const commandCount = document.querySelector("#command-count");
const activity = document.querySelector("#activity");
const connectionStatus = document.querySelector("#connection-status");
const demoBanner = document.querySelector("#demo-banner");
const authorPanel = document.querySelector("#author-panel");
const authorForm = document.querySelector("#author-form");
const authorText = document.querySelector("#author-text");
const authorCheck = document.querySelector("#author-check");
const authorSave = document.querySelector("#author-save");
const authorPreview = document.querySelector("#author-preview");
const authorEyebrow = document.querySelector("#author-eyebrow");
const authorTitle = document.querySelector("#author-title");
const authorCancel = document.querySelector("#author-cancel");
const authorDelete = document.querySelector("#author-delete");
const deleteDialog = document.querySelector("#delete-dialog");
const deleteCommandName = document.querySelector("#delete-command-name");
const deleteConfirm = document.querySelector("#delete-confirm");

let launcherToken = "";
let busy = false;
let checkedText = "";
let editingCommand = null;

bootstrap().catch((error) => showError(error));

async function bootstrap() {
  const response = await fetch("/api/bootstrap", { cache: "no-store" });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error?.message ?? "The launcher could not start");
  launcherToken = data.token;
  if (data.mode === "demo") demoBanner.classList.remove("hidden");
  if (data.authoring) authorPanel.classList.remove("hidden");
  renderCommands(data.commands);
}

authorForm?.addEventListener("submit", (event) => {
  event.preventDefault();
  void checkDraft();
});
authorSave?.addEventListener("click", () => void saveDraft());
authorCancel?.addEventListener("click", () => resetAuthorPanel());
authorDelete?.addEventListener("click", () => {
  if (!editingCommand || busy) return;
  deleteCommandName.textContent = editingCommand.name;
  deleteDialog.showModal();
});
deleteDialog?.addEventListener("close", () => {
  if (deleteDialog.returnValue === "delete") void deleteEditedCommand();
});
authorText?.addEventListener("input", () => {
  // Any edit invalidates the preflight the Save button was granted for.
  if (authorText.value.trim() !== checkedText) disableSave();
});

async function checkDraft() {
  const text = authorText.value.trim();
  if (!text || busy) return;
  disableSave();
  authorCheck.disabled = true;
  try {
    const proposal = await api("/api/author", {
      text,
      ...(editingCommand ? { commandId: editingCommand.id } : {})
    });
    renderProposal(proposal);
    if (proposal.saveable) {
      checkedText = text;
      authorSave.disabled = false;
    }
  } catch (error) {
    renderAuthorError(error);
  } finally {
    authorCheck.disabled = false;
  }
}

async function saveDraft() {
  const text = authorText.value.trim();
  if (!text || text !== checkedText || busy) return;
  authorSave.disabled = true;
  try {
    const result = editingCommand
      ? await api("/api/update", { commandId: editingCommand.id, text })
      : await api("/api/save", { text });
    renderCommands(result.commands);
    const saved = result.updated ?? result.saved;
    const verb = editingCommand ? "Updated" : "Saved";
    resetAuthorPanel(false);
    disableSave();
    authorPreview.className = "author-preview saved";
    authorPreview.replaceChildren(element("h3", `${verb} ${saved.name}`),
      element("p", "It is in your saved commands now. Press Run when you are ready."));
  } catch (error) {
    renderAuthorError(error);
  }
}

async function deleteEditedCommand() {
  if (!editingCommand || busy) return;
  const deleting = editingCommand;
  busy = true;
  setButtonsDisabled(true);
  authorDelete.disabled = true;
  try {
    const result = await api("/api/delete", { commandId: deleting.id });
    renderCommands(result.commands);
    resetAuthorPanel(false);
    authorPreview.className = "author-preview saved";
    authorPreview.replaceChildren(
      element("h3", `Deleted ${deleting.name}`),
      element("p", "It has been removed from your saved commands.")
    );
  } catch (error) {
    renderAuthorError(error);
  } finally {
    busy = false;
    authorDelete.disabled = false;
    setButtonsDisabled(false);
  }
}

function renderProposal(proposal) {
  authorPreview.className = `author-preview ${proposal.saveable ? "ready" : "blocked"}`;
  const list = document.createElement("ol");
  list.className = "author-steps";
  for (const step of proposal.steps) {
    list.append(element("li", step.plain));
  }
  authorPreview.replaceChildren(
    element("h3", proposal.command.name),
    element("p", proposal.saveable
      ? "Checked with no phone action. Here is what it would do:"
      : "Here is what it would do, but it cannot be saved yet:"),
    list
  );
  if (!proposal.saveable) {
    authorPreview.append(element("p", proposal.blockedReason ?? "The launcher cannot run this yet.", "author-blocked"));
  }
}

function renderAuthorError(error) {
  disableSave();
  authorPreview.className = "author-preview blocked";
  authorPreview.replaceChildren(
    element("h3", "That one is not ready"),
    element("p", error.message ?? String(error))
  );
}

function disableSave() {
  checkedText = "";
  if (authorSave) authorSave.disabled = true;
}

function editCommand(command) {
  if (!command.manageable || busy) return;
  editingCommand = command;
  checkedText = "";
  authorEyebrow.textContent = "Edit saved command";
  authorTitle.textContent = command.name;
  authorText.value = command.sourceText ?? "";
  authorCheck.textContent = "Check changes";
  authorSave.textContent = "Save changes";
  authorSave.disabled = true;
  authorCancel.classList.remove("hidden");
  authorDelete.classList.remove("hidden");
  authorPreview.className = "author-preview hidden";
  authorPanel.scrollIntoView({ behavior: "smooth", block: "center" });
  authorText.focus();
}

function resetAuthorPanel(clearPreview = true) {
  editingCommand = null;
  checkedText = "";
  authorEyebrow.textContent = "Create a command";
  authorTitle.textContent = "Describe a safe routine";
  authorText.value = "";
  authorCheck.textContent = "Check it";
  authorSave.textContent = "Save";
  authorSave.disabled = true;
  authorCancel.classList.add("hidden");
  authorDelete.classList.add("hidden");
  if (clearPreview) authorPreview.className = "author-preview hidden";
}

function element(tag, text, className) {
  const node = document.createElement(tag);
  node.textContent = text;
  if (className) node.className = className;
  return node;
}

function renderCommands(commands) {
  commandCount.textContent = `${commands.length} saved`;
  commandList.replaceChildren(...commands.map(commandCard));
}

function commandCard(command) {
  const card = document.createElement("article");
  card.className = "command-card";
  card.innerHTML = `
    <div class="command-icon" aria-hidden="true">
      <svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="8"></circle><path d="M12 8v8M8 12h8"></path></svg>
    </div>
    <div class="command-copy">
      <h3></h3>
      <p></p>
      <div class="command-meta"><span class="risk-badge"></span></div>
    </div>
    <div class="command-actions">
      <button class="run-button" type="button">Run</button>
    </div>`;
  card.querySelector("h3").textContent = command.name;
  card.querySelector("p").textContent = command.description;
  card.querySelector(".risk-badge").textContent = command.risk === "reversible" ? "Safe to undo" : command.risk;
  const actions = card.querySelector(".command-actions");
  const button = card.querySelector(".run-button");
  button.disabled = !command.enabled;
  if (!command.enabled) button.title = command.unavailableReason ?? "This command is not available";
  button.addEventListener("click", () => runCommand(command, button));
  if (command.manageable) {
    const manage = element("button", "Edit", "manage-button");
    manage.type = "button";
    manage.setAttribute("aria-label", `Edit ${command.name}`);
    manage.addEventListener("click", () => editCommand(command));
    actions.append(manage);
  }
  return card;
}

async function runCommand(command, button) {
  if (busy) return;
  busy = true;
  setButtonsDisabled(true);
  button.classList.add("loading");
  connectionStatus.innerHTML = "<span></span> Connecting";
  showActivity("running", "Checking everything first…", "No phone action has happened yet.");

  try {
    const check = await api("/api/dry-run", { commandId: command.id });
    if (!check.supported) throw new Error("This command is not supported by the current launcher.");
    showActivity("running", `Running ${command.name}…`, "Keep iPhone Mirroring visible. This usually takes a few seconds.");
    const receipt = await api("/api/run", { commandId: command.id });
    if (receipt.status !== "succeeded") {
      const error = new Error(receipt.error?.message ?? `The command ended as ${receipt.status}.`);
      error.code = receipt.error?.code;
      error.setupAction = receipt.error?.details?.setupAction;
      throw error;
    }
    connectionStatus.innerHTML = "<span></span> Connected";
    showActivity(
      "success",
      `${command.name} worked`,
      "The launcher saw the expected result on your mirrored iPhone.",
      `<span>${receipt.steps.length} verified step${receipt.steps.length === 1 ? "" : "s"}</span><span>${timeNow()}</span>`
    );
  } catch (error) {
    connectionStatus.innerHTML = "<span></span> Needs attention";
    showError(error);
  } finally {
    busy = false;
    button.classList.remove("loading");
    setButtonsDisabled(false);
  }
}

async function api(path, body) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json", "x-launcher-token": launcherToken },
    body: JSON.stringify(body)
  });
  const data = await response.json();
  if (!response.ok) {
    const error = new Error(data.error?.message ?? "The launcher could not complete that request");
    error.code = data.error?.code;
    error.setupAction = data.error?.setupAction;
    throw error;
  }
  return data;
}

function showError(error) {
  const setup = error.setupAction ? `<br><br><strong>One-time setup:</strong> ${escapeHtml(error.setupAction)}` : "";
  showActivity(
    "error",
    "That didn’t finish",
    `${escapeHtml(error.message ?? String(error))}${setup}`,
    `<span>${escapeHtml(error.code ?? "Try again")}</span><span>${timeNow()}</span>`,
    true
  );
}

function showActivity(kind, title, message, detail = "", messageIsHtml = false) {
  activity.className = `activity ${kind}`;
  activity.replaceChildren();
  const icon = document.createElement("div");
  icon.className = "activity-icon";
  icon.innerHTML = kind === "success"
    ? '<svg viewBox="0 0 24 24"><path d="m5 12 4 4 10-10"></path></svg>'
    : kind === "error"
      ? '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"></circle><path d="M12 7v6M12 17h.01"></path></svg>'
      : '<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="9"></circle><path d="M12 7v5l3 2"></path></svg>';
  const heading = document.createElement("h3");
  heading.textContent = title;
  const copy = document.createElement("p");
  if (messageIsHtml) copy.innerHTML = message;
  else copy.textContent = message;
  activity.append(icon, heading, copy);
  if (detail) {
    const row = document.createElement("div");
    row.className = "activity-detail";
    row.innerHTML = detail;
    activity.append(row);
  }
}

function setButtonsDisabled(disabled) {
  document.querySelectorAll(".command-card button").forEach((button) => {
    button.disabled = disabled || (button.classList.contains("run-button") && button.title.length > 0);
  });
  if (authorDelete) authorDelete.disabled = disabled;
}

function timeNow() {
  return new Intl.DateTimeFormat([], { hour: "numeric", minute: "2-digit" }).format(new Date());
}

function escapeHtml(value) {
  return String(value).replace(/[&<>'"]/g, character => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;"
  })[character]);
}

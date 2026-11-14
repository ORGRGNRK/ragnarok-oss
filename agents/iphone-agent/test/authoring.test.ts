import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import {
  CommandProtocolError,
  RuleBasedNaturalLanguageProvider,
  ValidatingNaturalLanguageAuthor,
  assessSafety,
  createGuidedCommand,
  parseCommand,
  serializeCommand,
  type AuthorPrompt,
  type PromptChoice
} from "../src/index.js";

const fixture = (path: string): Promise<string> =>
  readFile(new URL(`../fixtures/${path}`, import.meta.url), "utf8");

test("round-trips a canonical command through JSON and YAML", async () => {
  const command = parseCommand(await fixture("valid/open-settings.json"), "json");
  const json = parseCommand(serializeCommand(command, "json"), "json");
  const yaml = parseCommand(serializeCommand(command, "yaml"), "yaml");

  assert.deepEqual(json, command);
  assert.deepEqual(yaml, command);
});

test("authors supported safe natural-language patterns without a provider call", async () => {
  const author = new ValidatingNaturalLanguageAuthor(new RuleBasedNaturalLanguageProvider());
  const open = await author.author("Open Settings");
  const swipe = await author.author("Swipe up");

  assert.equal(open.id, "com.yggdrasil.iphone.open-settings");
  assert.equal(open.steps[0]?.action, "openApp");
  assert.equal(swipe.steps[0]?.action, "swipe");
});

test("rejects ambiguous natural-language requests instead of guessing", async () => {
  const author = new ValidatingNaturalLanguageAuthor(new RuleBasedNaturalLanguageProvider());

  await assert.rejects(
    author.author("Send a message to the owner"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "PARSE_ERROR"
  );
});

test("rejects invalid output from any future AI provider", async () => {
  const author = new ValidatingNaturalLanguageAuthor({
    async generate() {
      return { schemaVersion: "0.1", name: "Missing required fields" };
    }
  });

  await assert.rejects(
    author.author("do something"),
    (error: unknown) => error instanceof CommandProtocolError && error.code === "SCHEMA_INVALID"
  );
});

test("a provider cannot lower confirmation requirements with false", async () => {
  const author = new ValidatingNaturalLanguageAuthor({
    async generate() {
      return {
        schemaVersion: "0.1",
        id: "com.example.external",
        name: "External action",
        safety: { risk: "external", requiresConfirmation: false },
        steps: [
          {
            id: "send",
            action: "tap",
            target: { label: "Send" },
            safety: { risk: "external", requiresConfirmation: false }
          }
        ]
      };
    }
  });

  const command = await author.author("send something");
  assert.equal(assessSafety(command).requiresConfirmation, true);
  assert.deepEqual(assessSafety(command).confirmationStepIds, ["send"]);
});

test("guided authoring creates a validated command without AI", async () => {
  const prompt = new ScriptedPrompt(
    ["Open Settings", "com.example.open-settings", "", "open-settings", "Settings", "Settings", "Settings"],
    ["reversible", "openApp", "stop"],
    [false, false, false]
  );

  const command = await createGuidedCommand(prompt);

  assert.equal(command.id, "com.example.open-settings");
  assert.equal(command.steps[0]?.action, "openApp");
  assert.deepEqual(command.postconditions, [{ screenText: "Settings" }]);
});

class ScriptedPrompt implements AuthorPrompt {
  constructor(
    private readonly texts: string[],
    private readonly selections: string[],
    private readonly confirmations: boolean[]
  ) {}

  async text(_message: string, defaultValue?: string): Promise<string> {
    return this.texts.shift() ?? defaultValue ?? "";
  }

  async select<T extends string>(_message: string, choices: PromptChoice<T>[]): Promise<T> {
    const value = this.selections.shift();
    const choice = choices.find((candidate) => candidate.value === value);
    assert.ok(choice, `Missing scripted choice: ${value}`);
    return choice.value;
  }

  async confirm(_message: string, defaultValue = false): Promise<boolean> {
    return this.confirmations.shift() ?? defaultValue;
  }
}

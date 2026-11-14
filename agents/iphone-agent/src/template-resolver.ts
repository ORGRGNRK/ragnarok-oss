import { decode } from "jpeg-js";

import { CommandProtocolError } from "./errors.js";
import type {
  MirrorFrame,
  MirrorHostState,
  MirrorObservationResolver
} from "./runtime-types.js";
import type { ObservationCapability } from "./types.js";

export interface ScreenTemplate {
  label: string;
  frame: MirrorFrame;
  minimumConfidence?: number;
}

export interface TemplateResolverOptions {
  threshold?: number;
  signatureWidth?: number;
  signatureHeight?: number;
}

interface PreparedTemplate {
  label: string;
  signature: Float32Array;
  minimumConfidence: number;
}

export class TemplateScreenResolver implements MirrorObservationResolver {
  readonly capabilities: ObservationCapability[] = ["screenshot", "screenText"];
  private readonly templates: PreparedTemplate[];
  private readonly threshold: number;
  private readonly signatureWidth: number;
  private readonly signatureHeight: number;

  constructor(templates: ScreenTemplate[], options: TemplateResolverOptions = {}) {
    this.threshold = options.threshold ?? 0.82;
    this.signatureWidth = options.signatureWidth ?? 16;
    this.signatureHeight = options.signatureHeight ?? 24;
    this.templates = templates.map((template) => ({
      label: template.label,
      signature: this.signature(template.frame),
      minimumConfidence: template.minimumConfidence ?? this.threshold
    }));
  }

  async observe(state: MirrorHostState): Promise<{
    screenText?: string[];
    screenshotRef?: string;
    metadata?: Record<string, unknown>;
  }> {
    if (!state.frame?.bytes) {
      return {
        ...(state.frame?.reference ? { screenshotRef: state.frame.reference } : {}),
        metadata: { templateMatches: [] }
      };
    }

    const current = this.signature(state.frame);
    const matches = this.templates
      .map((template) => ({
        label: template.label,
        confidence: similarity(template.signature, current),
        minimumConfidence: template.minimumConfidence
      }))
      .sort((left, right) => right.confidence - left.confidence);
    const screenText = matches
      .filter((match) => match.confidence >= match.minimumConfidence)
      .map((match) => match.label);

    return {
      screenText,
      ...(state.frame.reference ? { screenshotRef: state.frame.reference } : {}),
      metadata: { templateMatches: matches }
    };
  }

  private signature(frame: MirrorFrame): Float32Array {
    if (!frame.bytes) {
      throw new CommandProtocolError("DRIVER_ERROR", "A screen template is missing image bytes");
    }
    if (frame.mediaType && frame.mediaType !== "image/jpeg") {
      throw new CommandProtocolError(
        "DRIVER_ERROR",
        `Template resolver supports image/jpeg frames; received ${frame.mediaType}`
      );
    }

    const image = decode(frame.bytes, { useTArray: true, formatAsRGBA: true });
    const output = new Float32Array(this.signatureWidth * this.signatureHeight);
    for (let targetY = 0; targetY < this.signatureHeight; targetY += 1) {
      const sourceY = Math.min(image.height - 1, Math.floor(((targetY + 0.5) * image.height) / this.signatureHeight));
      for (let targetX = 0; targetX < this.signatureWidth; targetX += 1) {
        const sourceX = Math.min(image.width - 1, Math.floor(((targetX + 0.5) * image.width) / this.signatureWidth));
        const offset = (sourceY * image.width + sourceX) * 4;
        output[targetY * this.signatureWidth + targetX] =
          (image.data[offset] * 0.2126 + image.data[offset + 1] * 0.7152 + image.data[offset + 2] * 0.0722) / 255;
      }
    }
    return output;
  }
}

function similarity(left: Float32Array, right: Float32Array): number {
  if (left.length !== right.length || left.length === 0) return 0;
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) {
    difference += Math.abs(left[index] - right[index]);
  }
  return Math.max(0, 1 - difference / left.length);
}

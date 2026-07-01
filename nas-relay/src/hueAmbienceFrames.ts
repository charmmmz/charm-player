import { rotatePalette } from './huePalette.js';
import {
  averagePosition,
  buildSpatialLightColors,
  compareSpatialPositions,
  isSpatialPosition,
  positionedChannelsForLight,
  type HueSpatialPosition,
} from './hueSpatialAmbience.js';
import type {
  HueAmbienceFrameReason,
  HueAmbienceMotionStyle,
  HueAmbienceRenderMode,
  HueAmbienceToneControl,
  HueAreaResource,
  HueEntertainmentChannelResource,
  HueLightResource,
  HueRGBColor,
  HueResolvedAmbienceTarget,
  HueSnapshot,
} from './hueTypes.js';

const white: HueRGBColor = { r: 1, g: 1, b: 1 };

export interface HueAmbienceLightFrame {
  light: HueLightResource;
  colors: HueRGBColor[];
  channelID?: string | null;
}

export interface HueAmbienceTargetFrame {
  area: HueAreaResource;
  lights: HueAmbienceLightFrame[];
  metadataComplete: boolean;
}

export interface HueAmbienceFrame {
  mode: HueAmbienceRenderMode;
  targets: HueAmbienceTargetFrame[];
  transitionSeconds: number;
  reason: HueAmbienceFrameReason;
  createdAt: Date;
  groupMemberCount?: number;
  metadataComplete: boolean;
  phase: number;
  progressOffset: number;
  effect?: HueAmbienceFrameEffect;
}

export interface HueAmbienceFrameEffect {
  source: string;
  reason: string;
  effectKey?: string;
  mode?: string;
  transitionSeconds?: number;
  attackSeconds?: number;
  holdSeconds?: number;
  fadeSeconds?: number;
  effectPhase?: string;
  cadenceMs?: number;
  remainingMs?: number;
  strength?: number;
}

export interface BuildHueAmbienceFrameInput {
  targets: HueResolvedAmbienceTarget[];
  snapshot: HueSnapshot;
  palette: HueRGBColor[];
  reason: HueAmbienceFrameReason;
  phase: number;
  transitionSeconds: number;
  now?: Date;
  effect?: HueAmbienceFrameEffect;
  motionStyle?: HueAmbienceMotionStyle;
  toneControl?: HueAmbienceToneControl;
}

interface LightFrameSource {
  light: HueLightResource;
  channelID?: string | null;
  offsetIndex: number;
  position?: HueSpatialPosition | null;
  segmentPositions?: HueSpatialPosition[];
}

export function buildHueAmbienceFrame(input: BuildHueAmbienceFrameInput): HueAmbienceFrame {
  const palette = input.palette.length > 0 ? input.palette : [white];
  const progressOffset = playbackProgressOffset(input.snapshot, palette.length);
  const mode: HueAmbienceRenderMode = input.targets.some(target => target.area.kind === 'entertainmentArea')
    ? 'streamingReady'
    : 'clipFallback';
  const targetFrames = input.targets.map((target, targetIndex) => {
    const metadataComplete = entertainmentMetadataComplete(target.area);
    const frameSources = lightFrameSources(target);
    return {
      area: target.area,
      lights: frameSources.map(source =>
        buildLightFrame(
          source.light,
          target.area,
          palette,
          input.phase + progressOffset + targetIndex + source.offsetIndex,
          input.motionStyle,
          input.toneControl,
          source.channelID,
          source.position,
          source.segmentPositions,
        ),
      ),
      metadataComplete,
    };
  });
  const entertainmentTargetFrames = targetFrames.filter(target => target.area.kind === 'entertainmentArea');

  return {
    mode,
    targets: targetFrames,
    transitionSeconds: input.transitionSeconds,
    reason: input.reason,
    createdAt: input.now ?? new Date(),
    groupMemberCount: input.snapshot.groupMemberCount,
    metadataComplete: entertainmentTargetFrames.length > 0
      && entertainmentTargetFrames.every(target => target.metadataComplete),
    phase: input.phase,
    progressOffset,
    ...(input.effect ? { effect: input.effect } : {}),
  };
}

export function entertainmentMetadataComplete(area: HueAreaResource): boolean {
  if (area.kind !== 'entertainmentArea') return false;
  const channelLightIDs = new Set(
    (area.entertainmentChannels ?? [])
      .map(channel => channel.lightID)
      .filter((lightID): lightID is string => typeof lightID === 'string' && lightID.length > 0),
  );

  return area.childLightIDs.length > 0 && area.childLightIDs.every(lightID => channelLightIDs.has(lightID));
}

function lightFrameSources(target: HueResolvedAmbienceTarget): LightFrameSource[] {
  if (target.area.kind !== 'entertainmentArea') {
    const positionRanks = roomLightSpatialRanks(target);
    return target.lights.map((light, index) => {
      const segmentPositions = positionedChannelsForLight(target.area.entertainmentChannels, light.id);
      const position = averagePosition(segmentPositions);
      return {
        light,
        offsetIndex: positionRanks?.get(light.id) ?? index,
        ...(position ? { position } : {}),
        ...(segmentPositions.length > 0 ? { segmentPositions } : {}),
      };
    });
  }

  const lightsByID = new Map(target.lights.map(light => [light.id, light]));
  const channelSources = (target.area.entertainmentChannels ?? [])
    .map((channel, index) => {
      const light = channel.lightID ? lightsByID.get(channel.lightID) : undefined;
      return light ? { light, channel, fallbackIndex: index } : null;
    })
    .filter((source): source is {
      light: HueLightResource;
      channel: HueEntertainmentChannelResource;
      fallbackIndex: number;
    } => source !== null);

  if (channelSources.length === 0) {
    return target.lights.map((light, index) => ({ light, offsetIndex: index }));
  }

  const spatialRanks = entertainmentChannelSpatialRanks(channelSources);
  return channelSources.map(source => ({
    light: source.light,
    channelID: source.channel.id,
    offsetIndex: spatialRanks?.get(source.channel.id) ?? source.fallbackIndex,
    ...(isSpatialPosition(source.channel.position) ? { position: source.channel.position } : {}),
  }));
}

function roomLightSpatialRanks(target: HueResolvedAmbienceTarget): Map<string, number> | null {
  const positionedLights = target.lights.map(light => {
    const position = averagePosition(positionedChannelsForLight(target.area.entertainmentChannels, light.id));
    return position ? { lightID: light.id, position } : null;
  });

  if (positionedLights.some(light => light === null)) return null;

  return new Map(
    positionedLights
      .filter((light): light is NonNullable<typeof light> => light !== null)
      .sort((a, b) => compareSpatialPositions(a.position, b.position) || a.lightID.localeCompare(b.lightID))
      .map((light, index) => [light.lightID, index]),
  );
}

function entertainmentChannelSpatialRanks(
  channelSources: Array<{
    channel: HueEntertainmentChannelResource;
  }>,
): Map<string, number> | null {
  const positionedChannels = channelSources.map(source => {
    const position = source.channel.position;
    if (
      !position
      || !Number.isFinite(position.x)
      || !Number.isFinite(position.y)
      || !Number.isFinite(position.z)
    ) {
      return null;
    }

    return { channelID: source.channel.id, position };
  });

  if (positionedChannels.some(channel => channel === null)) return null;

  return new Map(
    positionedChannels
      .filter((channel): channel is NonNullable<typeof channel> => channel !== null)
      .sort((a, b) =>
        a.position.x - b.position.x
        || a.position.z - b.position.z
        || a.position.y - b.position.y
        || a.channelID.localeCompare(b.channelID),
      )
      .map((channel, index) => [channel.channelID, index]),
  );
}

function buildLightFrame(
  light: HueLightResource,
  area: HueAreaResource,
  palette: HueRGBColor[],
  offset: number,
  motionStyle?: HueAmbienceMotionStyle,
  toneControl?: HueAmbienceToneControl,
  channelIDOverride?: string | null,
  position?: HueSpatialPosition | null,
  segmentPositions?: HueSpatialPosition[],
): HueAmbienceLightFrame {
  const colors = motionStyle
    ? buildSpatialLightColors({
      light,
      palette,
      phase: offset,
      offset,
      motionStyle,
      position,
      segmentPositions: channelIDOverride ? undefined : segmentPositions,
      toneControl,
    })
    : rotatePalette(palette, offset).slice(0, light.supportsGradient ? 5 : 1);
  const channelID = channelIDOverride ?? area.entertainmentChannels?.find(channel => channel.lightID === light.id)?.id;

  return {
    light,
    ...(channelID ? { channelID } : {}),
    colors,
  };
}

function playbackProgressOffset(snapshot: HueSnapshot, paletteLength: number): number {
  if (paletteLength <= 0 || snapshot.durationSeconds <= 0 || snapshot.positionSeconds < 0) return 0;
  const progress = Math.min(Math.max(snapshot.positionSeconds / snapshot.durationSeconds, 0), 1);
  return Math.floor(progress * paletteLength) % paletteLength;
}

"use client";

import { FilePen, LoaderCircle, MessageSquare, SquareCheck, Terminal } from "lucide-react";
import type { LucideIcon } from "lucide-react";
import type { Edge as FlowEdge, Node as FlowNode, NodeProps } from "@xyflow/react";
import { Canvas } from "@/components/ai-elements/canvas";
import { Edge } from "@/components/ai-elements/edge";
import {
  Node,
  NodeContent,
  NodeDescription,
  NodeFooter,
  NodeHeader,
  NodeTitle,
} from "@/components/ai-elements/node";
import { Task, TaskContent, TaskItem, TaskTrigger } from "@/components/ai-elements/task";
import type { LiveAgent } from "../contract";

/**
 * The live workflow is a fixed, user-facing pipeline. The event stream only
 * decides which step is active; it does not create or remove steps.
 */
export function AgentTimeline({ completed = false, live }: { completed?: boolean; live: Pick<LiveAgent, "phase"> }) {
  const activeStep = activeStepFor(live);
  const { nodes, edges } = buildWorkflow(activeStep, completed);

  return (
    <>
      <div className="hidden h-80 overflow-hidden rounded-lg border bg-background md:block">
        <Canvas
          edges={edges}
          edgeTypes={edgeTypes}
          fitView
          nodes={nodes}
          nodeTypes={nodeTypes}
          nodesDraggable={false}
          nodesConnectable={false}
          proOptions={{ hideAttribution: true }}
        />
      </div>
      <Task defaultOpen className="md:hidden">
        <TaskTrigger title="6 workflow steps" />
        <TaskContent>
          {PIPELINE.map((step) => {
            const active = !completed && step.key === activeStep;
            const done = completed || step.order < orderFor(activeStep);
            const Icon = step.icon;

            return (
              <TaskItem key={step.key} className="flex items-start gap-2.5">
                {active ? (
                  <LoaderCircle className="mt-0.5 size-3.5 flex-none animate-spin text-emerald-600" aria-hidden />
                ) : done ? (
                  <SquareCheck className="mt-0.5 size-3.5 flex-none text-emerald-600" aria-hidden />
                ) : (
                  <Icon className="mt-0.5 size-3.5 flex-none text-muted-foreground" aria-hidden />
                )}
                <div className="min-w-0">
                  <p className="text-sm leading-snug text-foreground">{step.label}</p>
                  <p className="font-mono text-xs text-muted-foreground">
                    {active ? "current" : done ? "done" : "next"}
                  </p>
                </div>
              </TaskItem>
            );
          })}
        </TaskContent>
      </Task>
    </>
  );
}

type PipelineStepKey = "start" | "plan" | "build" | "verify" | "review" | "handoff";

type PipelineStep = {
  key: PipelineStepKey;
  order: number;
  label: string;
  description: string;
  icon: LucideIcon;
};

const PIPELINE: PipelineStep[] = [
  {
    key: "start",
    order: 1,
    label: "Start",
    description: "Agent picked up the issue",
    icon: Terminal,
  },
  {
    key: "plan",
    order: 2,
    label: "Plan",
    description: "Read the ticket and shape the approach",
    icon: MessageSquare,
  },
  {
    key: "build",
    order: 3,
    label: "Build",
    description: "Edit code and address the request",
    icon: FilePen,
  },
  {
    key: "verify",
    order: 4,
    label: "Verify",
    description: "Run checks and capture proof",
    icon: Terminal,
  },
  {
    key: "review",
    order: 5,
    label: "Review",
    description: "Prepare PR, CI and handoff",
    icon: SquareCheck,
  },
  {
    key: "handoff",
    order: 6,
    label: "Handoff",
    description: "Ready for human review",
    icon: SquareCheck,
  },
];

type WorkflowNodeData = {
  active: boolean;
  description: string;
  handles: { target: boolean; source: boolean };
  icon: LucideIcon;
  label: string;
  state: "done" | "active" | "next";
  step: number;
};

const nodeTypes = {
  workflow: ({ data }: NodeProps<FlowNode<WorkflowNodeData>>) => {
    const Icon = data.icon;

    return (
      <Node
        handles={data.handles}
        className={`w-48 ${data.active ? "border-emerald-300 bg-emerald-50" : data.state === "done" ? "bg-muted/30" : ""}`}
      >
        <NodeHeader>
          <NodeTitle className="flex items-center justify-between gap-2 text-sm">
            <span>{data.label}</span>
            {data.active ? (
              <LoaderCircle className="size-3.5 animate-spin text-emerald-600" aria-hidden />
            ) : data.state === "done" ? (
              <SquareCheck className="size-3.5 text-emerald-600" aria-hidden />
            ) : (
              <Icon className="size-3.5 text-muted-foreground" aria-hidden />
            )}
          </NodeTitle>
          <NodeDescription className="text-foreground">{data.active ? "current" : data.state}</NodeDescription>
        </NodeHeader>
        <NodeContent>
          <p className="line-clamp-3 min-h-14 text-sm leading-snug">{data.description}</p>
        </NodeContent>
        <NodeFooter>
          <p className="truncate font-mono text-[11px] text-foreground">step {data.step}</p>
        </NodeFooter>
      </Node>
    );
  },
};

const edgeTypes = {
  animated: Edge.Animated,
  temporary: Edge.Temporary,
};

function buildWorkflow(activeStep: PipelineStepKey, completed = false) {
  const activeOrder = orderFor(activeStep);
  const nodes: FlowNode<WorkflowNodeData>[] = PIPELINE.map((step, index) => ({
    id: nodeId(index),
    position: { x: index * 230, y: 60 },
    type: "workflow",
    data: {
      active: !completed && step.key === activeStep,
      description: step.description,
      handles: { target: index > 0, source: index < PIPELINE.length - 1 },
      icon: step.icon,
      label: step.label,
      state: completed ? "done" : step.order < activeOrder ? "done" : step.key === activeStep ? "active" : "next",
      step: step.order,
    },
  }));

  const edges: FlowEdge[] = PIPELINE.slice(1).map((_step, index) => ({
    id: `edge-${index}`,
    source: nodeId(index),
    target: nodeId(index + 1),
    type: completed || index + 1 < activeOrder ? "animated" : "temporary",
  }));

  return { nodes, edges };
}

function nodeId(index: number) {
  return `live-step-${index}`;
}

function orderFor(step: PipelineStepKey) {
  return PIPELINE.find((item) => item.key === step)?.order ?? 1;
}

function activeStepFor(live: Pick<LiveAgent, "phase">): PipelineStepKey {
  switch (live.phase) {
    case "starting":
      return "start";
    case "planning":
      return "plan";
    case "building":
    case "blocked":
      return "build";
    case "verifying":
      return "verify";
    case "reviewing":
    case "failed":
    case "cancelled":
      return "review";
    case "handoff":
      return "handoff";
  }
}

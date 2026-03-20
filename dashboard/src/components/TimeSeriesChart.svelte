<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import { Chart, registerables } from "chart.js";
  import type { TimeSeriesPoint } from "../lib/api";

  Chart.register(...registerables);

  let { data, selectedDate = "", onDateClick }: {
    data: TimeSeriesPoint[];
    selectedDate?: string;
    onDateClick: (date: string) => void;
  } = $props();

  let canvas: HTMLCanvasElement;
  let chart: Chart | null = null;

  function getDisplayData(points: TimeSeriesPoint[], sel: string): TimeSeriesPoint[] {
    if (!sel) return points;
    const idx = points.findIndex((p) => p.date === sel);
    if (idx === -1) return points;
    return points.slice(Math.max(0, idx - 1), idx + 2);
  }

  function render(points: TimeSeriesPoint[], sel: string) {
    if (chart) chart.destroy();
    if (!canvas) return;

    const display = getDisplayData(points, sel);
    const labels = display.map((p) => p.date);

    chart = new Chart(canvas, {
      type: "line",
      data: {
        labels,
        datasets: [
          {
            label: "Fail",
            data: display.map((p) => p.fail_count),
            borderColor: "#dc2626",
            backgroundColor: "rgba(220, 38, 38, 0.1)",
            fill: true,
            tension: 0.3,
            pointRadius: display.map((p) => (p.date === sel ? 7 : 4)),
            pointHoverRadius: 7,
          },
          {
            label: "Pass",
            data: display.map((p) => p.pass_count),
            borderColor: "#16a34a",
            backgroundColor: "rgba(22, 163, 74, 0.1)",
            fill: true,
            tension: 0.3,
            pointRadius: display.map((p) => (p.date === sel ? 7 : 4)),
            pointHoverRadius: 7,
          },
        ],
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { position: "top" },
        },
        scales: {
          x: {
            ticks: {
              maxRotation: 0,
              callback(_val: string | number, i: number) {
                const d = new Date(labels[i] + "T00:00:00");
                return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
              },
            },
          },
          y: { beginAtZero: true },
        },
        onClick(_event, elements) {
          if (elements.length > 0) {
            onDateClick(labels[elements[0].index]);
          }
        },
        onHover(event) {
          const target = event.native?.target as HTMLElement | null;
          if (target) target.style.cursor = "pointer";
        },
      },
    });
  }

  onMount(() => render(data, selectedDate));
  $effect(() => render(data, selectedDate));
  onDestroy(() => chart?.destroy());
</script>

<div class="chart-container">
  <div class="chart-header">
    <h3>Messages Over Time{selectedDate ? ` — ${selectedDate}` : ""}</h3>
    {#if selectedDate}
      <button class="revert-btn" onclick={() => onDateClick("")}>← All {"\u00A0"}</button>
    {/if}
  </div>
  <div class="chart-wrapper">
    <canvas bind:this={canvas}></canvas>
  </div>
</div>

<style>
  .chart-container {
    background: var(--card-bg, #fff);
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 8px;
    padding: 1.25rem;
    margin-bottom: 1.5rem;
  }
  .chart-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;
  }
  h3 {
    margin: 0;
    font-size: 1rem;
  }
  .revert-btn {
    padding: 0.3rem 0.7rem;
    border: 1px solid var(--border, #e2e8f0);
    border-radius: 4px;
    background: var(--card-bg, #fff);
    color: var(--text, #1e293b);
    cursor: pointer;
    font-size: 0.8rem;
  }
  .revert-btn:hover { background: var(--border, #e2e8f0); }
  .chart-wrapper {
    position: relative;
    height: 300px;
  }
</style>

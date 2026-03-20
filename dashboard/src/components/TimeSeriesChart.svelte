<script lang="ts">
  import { onMount, onDestroy } from "svelte";
  import { Chart, registerables } from "chart.js";
  import type { TimeSeriesPoint } from "../lib/api";

  Chart.register(...registerables);

  let { data }: { data: TimeSeriesPoint[] } = $props();
  let canvas: HTMLCanvasElement;
  let chart: Chart | null = null;

  function render(points: TimeSeriesPoint[]) {
    if (chart) chart.destroy();
    if (!canvas) return;

    const labels = points.map((p) => p.date);

    chart = new Chart(canvas, {
      type: "line",
      data: {
        labels,
        datasets: [
          {
            label: "Fail",
            data: points.map((p) => p.fail_count),
            borderColor: "#dc2626",
            backgroundColor: "rgba(220, 38, 38, 0.1)",
            fill: true,
            tension: 0.3,
          },
          {
            label: "Pass",
            data: points.map((p) => p.pass_count),
            borderColor: "#16a34a",
            backgroundColor: "rgba(22, 163, 74, 0.1)",
            fill: true,
            tension: 0.3,
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
      },
    });
  }

  onMount(() => render(data));
  $effect(() => render(data));
  onDestroy(() => chart?.destroy());
</script>

<div class="chart-container">
  <h3>Messages Over Time</h3>
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
  h3 {
    margin: 0 0 1rem 0;
    font-size: 1rem;
  }
  .chart-wrapper {
    position: relative;
    height: 300px;
  }
</style>

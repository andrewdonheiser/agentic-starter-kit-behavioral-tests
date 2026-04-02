"""Rich console reporter for eval scores and results."""

from __future__ import annotations

from rich.console import Console
from rich.table import Table

from harness.runner import EvalResult
from harness.scorers import Score


def print_scores(scores: list[Score], title: str = "Eval Scores") -> None:
    """Print a colored table of scores to the terminal."""
    console = Console()

    if not scores:
        console.print("[dim]No scores to display.[/dim]")
        return

    table = Table(title=title, show_lines=True)
    table.add_column("Scorer", style="cyan", no_wrap=True)
    table.add_column("Value", justify="right")
    table.add_column("Pass", justify="center")
    table.add_column("Details", max_width=60)

    for score in scores:
        value_str = f"{score.value:.2f}"
        if score.value >= 0.9:
            value_style = "green"
        elif score.value >= 0.6:
            value_style = "yellow"
        else:
            value_style = "red"

        pass_str = "[green]PASS[/green]" if score.passed else "[red]FAIL[/red]"

        # Compact details string
        details_parts: list[str] = []
        for k, v in score.details.items():
            if isinstance(v, list) and len(v) > 3:
                details_parts.append(f"{k}: [{len(v)} items]")
            elif isinstance(v, float):
                details_parts.append(f"{k}: {v:.3f}")
            else:
                details_parts.append(f"{k}: {v}")
        details_str = ", ".join(details_parts) if details_parts else ""

        table.add_row(
            score.name,
            f"[{value_style}]{value_str}[/{value_style}]",
            pass_str,
            details_str,
        )

    console.print(table)

    # Summary line
    passed = sum(1 for s in scores if s.passed)
    total = len(scores)
    avg = sum(s.value for s in scores) / total
    status = "[green]ALL PASSED[/green]" if passed == total else "[red]FAILURES[/red]"
    console.print(
        f"\n{status} | {passed}/{total} passed | avg score: {avg:.2f}\n"
    )


def print_results(results: list[EvalResult], title: str = "Eval Results") -> None:
    """Print a summary table of EvalResults to the terminal."""
    console = Console()

    if not results:
        console.print("[dim]No results to display.[/dim]")
        return

    table = Table(title=title, show_lines=True)
    table.add_column("#", justify="right", style="dim")
    table.add_column("Status", justify="center")
    table.add_column("Latency", justify="right")
    table.add_column("Tokens", justify="right")
    table.add_column("Tools", justify="right")
    table.add_column("Error", max_width=40)

    for i, r in enumerate(results, 1):
        status = "[green]OK[/green]" if r.success else "[red]FAIL[/red]"
        latency = f"{r.latency_seconds:.2f}s"
        tokens = str(r.tokens_used) if r.tokens_used is not None else "-"
        tools = str(len(r.tool_calls))
        error = (r.error or "")[:40]

        table.add_row(str(i), status, latency, tokens, tools, error)

    console.print(table)

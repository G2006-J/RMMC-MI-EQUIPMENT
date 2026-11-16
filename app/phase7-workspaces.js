"use client";

import { useEffect, useState } from "react";
import { ArrowLeft, ArrowLeftRight, ArrowRight, ClipboardList, Clock3, Download, Package, Printer, Search, ShieldAlert } from "lucide-react";
import { downloadCsv } from "@/lib/csv.mjs";
import { formatManilaDateTime } from "@/lib/datetime.mjs";
import { createReportPrintHtml } from "@/lib/report-print.mjs";

const REPORT_TYPES = [
  { id: "utilization", title: "Utilization", description: "Borrowed unit-days against available unit-days." },
  { id: "most_borrowed", title: "Most borrowed", description: "Top 20 equipment by borrowing count." },
  { id: "damage_loss", title: "Damaged or loss", description: "Reported units grouped by resolution status and equipment." },
  { id: "overdue", title: "Overdue", description: "Current overdue items grouped by equipment and borrower." },
  { id: "return_history", title: "History", description: "Recorded return date, time, and condition for each item." },
];

function dateValue(date) {
  return date.toISOString().slice(0, 10);
}

function dateDaysAgo(days) {
  const date = new Date();
  date.setDate(date.getDate() - days);
  return dateValue(date);
}

function initialStartDate() {
  return dateDaysAgo(29);
}

async function loadReport(supabase, reportId, startDate, endDate, page = 0, exportReport = false) {
  const request = reportId === "return_history"
    ? supabase.rpc("get_phase7_return_history_report", {
      p_start_date: startDate || null,
      p_end_date: endDate || null,
      p_page: page,
      p_export: exportReport,
    })
    : supabase.rpc("get_phase7_report", {
      p_report_type: reportId,
      p_start_date: startDate || null,
      p_end_date: endDate || null,
      p_page: page,
      p_export: exportReport,
    });
  const { data, error } = await request;
  if (error) throw error;
  return data;
}

function MetricCard({ label, value, detail, Icon, color }) {
  return (
    <article className="metric-card">
      <div className="metric-top"><span>{label}</span><span className={`metric-icon ${color}`}><Icon size={18} /></span></div>
      <strong>{value ?? "—"}</strong>
      <small>{detail}</small>
    </article>
  );
}

export function OverviewStatistics({ supabase, isManager, borrowerId, pendingRequestCount, loading }) {
  const [statistics, setStatistics] = useState(null);

  useEffect(() => {
    let active = true;
    async function loadStatistics() {
      setStatistics(null);
      if (isManager) {
        const today = dateValue(new Date());
        const reportCalls = [
          ["utilization", initialStartDate(), today],
          ["overdue", dateDaysAgo(365), today],
          ["damage_loss", initialStartDate(), today],
        ];
        const [reports, borrowedResult] = await Promise.all([
          Promise.all(reportCalls.map(async ([id, start, end]) => {
            try {
              return [id, await loadReport(supabase, id, start, end)];
            } catch (reportError) {
              console.error(`The ${id} overview statistic could not be loaded:`, reportError);
              return [id, null];
            }
          })),
          supabase.from("borrowings")
            .select("borrowing_id", { count: "exact", head: true })
            .in("transaction_status", ["released", "overdue"]),
        ]);
        if (!active) return;
        if (borrowedResult.error) console.error("The currently borrowed count could not be loaded:", borrowedResult.error);
        const reportData = Object.fromEntries(reports);
        setStatistics({
          totalEquipment: reportData.utilization?.total_count ?? null,
          currentlyBorrowed: borrowedResult.error ? null : borrowedResult.count || 0,
          overdue: reportData.overdue?.total_count ?? null,
          damageLoss: reportData.damage_loss?.total_count ?? null,
        });
        return;
      }

      if (borrowerId === null || borrowerId === undefined) {
        if (active) setStatistics({ activeBorrowings: 0, overdue: 0 });
        return;
      }
      const [activeBorrowings, overdueBorrowings] = await Promise.all([
        supabase.from("borrowings")
          .select("borrowing_id", { count: "exact", head: true })
          .eq("borrower_id", borrowerId)
          .in("transaction_status", ["approved", "released", "overdue"]),
        supabase.from("borrowings")
          .select("borrowing_id, borrowing_items!inner(borrowing_item_id)", { count: "exact", head: true })
          .eq("borrower_id", borrowerId)
          .eq("transaction_status", "released")
          .eq("borrowing_items.item_status", "released")
          .eq("borrowing_items.is_overdue", true),
      ]);
      if (!active) return;
      if (activeBorrowings.error) console.error("The borrower active-borrowing count could not be loaded:", activeBorrowings.error);
      if (overdueBorrowings.error) console.error("The borrower overdue count could not be loaded:", overdueBorrowings.error);
      setStatistics({
        activeBorrowings: activeBorrowings.error ? null : activeBorrowings.count || 0,
        overdue: overdueBorrowings.error ? null : overdueBorrowings.count || 0,
      });
    }

    loadStatistics().catch((loadError) => {
      console.error("Overview statistics could not be loaded:", loadError);
      if (active) setStatistics({});
    });
    return () => { active = false; };
  }, [supabase, isManager, borrowerId]);

  const metricValue = (value) => loading || statistics === null ? "—" : value ?? "—";
  return (
    <section className={`overview-report-grid ${isManager ? "" : "overview-borrower-grid"}`} aria-label="Overview statistics">
      {isManager ? (
        <>
          <MetricCard label="Total equipment" value={metricValue(statistics?.totalEquipment)} detail="Active inventory records" Icon={Package} color="metric-green" />
          <MetricCard label="Currently borrowed" value={metricValue(statistics?.currentlyBorrowed)} detail="Released or overdue borrowings" Icon={ArrowLeftRight} color="metric-amber" />
          <MetricCard label="Overdue" value={metricValue(statistics?.overdue)} detail="Overdue equipment/borrower groups" Icon={Clock3} color="metric-rose" />
          <MetricCard label="Pending requests" value={loading ? "—" : pendingRequestCount} detail="Borrowing and reservation requests" Icon={ClipboardList} color="metric-blue" />
          <MetricCard label="Damaged or lost" value={metricValue(statistics?.damageLoss)} detail="Equipment/status groups · 30 days" Icon={ShieldAlert} color="metric-rose" />
        </>
      ) : (
        <>
          <MetricCard label="Active borrowings" value={metricValue(statistics?.activeBorrowings)} detail="Your approved or released requests" Icon={ArrowLeftRight} color="metric-amber" />
          <MetricCard label="Overdue" value={metricValue(statistics?.overdue)} detail="Your overdue borrowing records" Icon={Clock3} color="metric-rose" />
        </>
      )}
    </section>
  );
}

export function ReportsWorkspace({ supabase }) {
  const [startDate, setStartDate] = useState(initialStartDate);
  const [endDate, setEndDate] = useState(() => dateValue(new Date()));
  const [pages, setPages] = useState({});
  const [activeReportId, setActiveReportId] = useState(REPORT_TYPES[0].id);
  const [reports, setReports] = useState({});
  const [loading, setLoading] = useState(false);
  const [exporting, setExporting] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    loadReport(supabase, activeReportId, startDate, endDate, pages[activeReportId] || 0).then((data) => {
      if (active) setReports((current) => ({ ...current, [activeReportId]: data }));
    }).catch((loadError) => {
      console.error("Reports could not be loaded:", loadError);
      if (active) setError("Reports are unavailable right now.");
    }).finally(() => {
      if (active) setLoading(false);
    });
    return () => { active = false; };
  }, [supabase, activeReportId, startDate, endDate, pages]);

  async function exportReport(report) {
    setError("");
    setNotice("");
    const printWindow = window.open("", "_blank");
    if (!printWindow) {
      setError("Allow pop-ups to open the PDF report.");
      return;
    }
    printWindow.opener = null;
    setExporting(report.id);
    try {
      const data = await loadReport(supabase, report.id, startDate, endDate, 0, true);
      const rows = data.rows.map((row) => row.map((value, valueIndex) => (
        report.id === "utilization" && valueIndex === 4
          ? `${(Number(value || 0) * 100).toFixed(1)}%`
          : value ?? "—"
      )));
      printWindow.document.open();
      printWindow.document.write(createReportPrintHtml({
        title: report.title,
        description: report.description,
        startDate,
        endDate,
        generatedAt: formatManilaDateTime(new Date()),
        headers: data.headers,
        rows,
        truncated: data.truncated,
      }));
      printWindow.document.close();
      printWindow.focus();
      window.setTimeout(() => {
        if (!printWindow.closed) printWindow.print();
      }, 250);
      setNotice(data.truncated
        ? `PDF print view opened. It includes the first 5,000 rows; ${data.total_count - 5000} additional rows were not included.`
        : `PDF print view opened for ${report.title} (${rows.length} rows). Choose Save as PDF to download it.`);
    } catch (exportError) {
      console.error("The report export could not be created:", exportError);
      printWindow.close();
      setError("The report export could not be created. Please try again.");
    } finally {
      setExporting("");
    }
  }

  return (
    <div className="phase7-workspace">
      <div className="report-date-toolbar">
        <label><span>Start date</span><input type="date" value={startDate} onChange={(event) => { setStartDate(event.target.value); setPages({}); }} /></label>
        <label><span>End date</span><input type="date" value={endDate} onChange={(event) => { setEndDate(event.target.value); setPages({}); }} /></label>
      </div>
      <div className="report-tabs" role="tablist" aria-label="Report category">
        {REPORT_TYPES.map((report) => (
          <button
            key={report.id}
            id={`report-tab-${report.id}`}
            className={activeReportId === report.id ? "active" : ""}
            type="button"
            role="tab"
            aria-selected={activeReportId === report.id}
            aria-controls={`report-panel-${report.id}`}
            onClick={() => setActiveReportId(report.id)}
          >
            {report.title}
          </button>
        ))}
      </div>
      {error && <p className="feedback feedback-error" role="alert">{error}</p>}
      {notice && <p className="feedback feedback-success" role="status">{notice}</p>}
      {REPORT_TYPES.filter((report) => report.id === activeReportId).map((report) => {
        const result = reports[report.id];
        const rows = result?.rows || [];
        const maxBorrowings = report.id === "most_borrowed"
          ? Math.max(1, ...rows.map((row) => Number(row[2] || 0)))
          : 1;
        return (
          <section className="phase7-report" key={report.id} id={`report-panel-${report.id}`} role="tabpanel" aria-labelledby={`report-tab-${report.id}`}>
            <div className="phase7-section-heading">
              <div><h2>{report.title}</h2><p>{report.description}</p></div>
              <div className="phase7-export-control">
                <button className="button-secondary" type="button" title="This file contains personal data. Handle it accordingly."
                  onClick={() => exportReport(report)} disabled={loading || Boolean(exporting)}>
                  <Printer size={14} /> {exporting === report.id ? "Preparing…" : "Download PDF"}
                </button>
                <small>Opens print settings; choose Save as PDF. Contains personal data.</small>
              </div>
            </div>
            {loading && !result ? <p className="phase7-empty">Loading report…</p> : rows.length === 0
              ? <p className="phase7-empty">No records for this date range.</p>
              : <div className="phase7-table-wrap"><table className="phase7-table">
                <thead><tr>{(result.headers || []).map((header) => <th key={header}>{header}</th>)}{report.id === "most_borrowed" && <th>Relative volume</th>}</tr></thead>
                <tbody>{rows.map((row, rowIndex) => <tr key={`${report.id}-${rowIndex}`}>
                  {row.map((value, valueIndex) => <td key={`${rowIndex}-${valueIndex}`}>{report.id === "utilization" && valueIndex === 4
                    ? `${(Number(value || 0) * 100).toFixed(1)}%`
                    : value ?? "—"}</td>)}
                  {report.id === "most_borrowed" && <td><span className="report-bar-track"><span style={{ width: `${Math.max(3, (Number(row[2] || 0) / maxBorrowings) * 100)}%` }} /></span></td>}
                </tr>)}</tbody>
              </table></div>}
            {report.id !== "most_borrowed" && Number(result?.total_count || 0) > 100 && <nav className="phase7-pagination" aria-label={`${report.title} pages`}>
              <span>Page {(pages[report.id] || 0) + 1} · {result.total_count} rows</span>
              <div>
                <button className="button-icon" type="button" aria-label="Previous page" title="Previous page"
                  onClick={() => setPages((current) => ({ ...current, [report.id]: Math.max(0, (current[report.id] || 0) - 1) }))}
                  disabled={!pages[report.id]}><ArrowLeft size={15} /></button>
                <button className="button-icon" type="button" aria-label="Next page" title="Next page"
                  onClick={() => setPages((current) => ({ ...current, [report.id]: (current[report.id] || 0) + 1 }))}
                  disabled={rows.length < 100}><ArrowRight size={15} /></button>
              </div>
            </nav>}
          </section>
        );
      })}
    </div>
  );
}

const AUDIT_HEADERS = ["Time", "Actor ID", "Event", "Entity", "Entity ID", "Source", "Before", "After"];

export function AuditLogWorkspace({ supabase, isAdmin }) {
  const [filters, setFilters] = useState({ start: "", end: "", actor: "", event: "", search: "" });
  const [page, setPage] = useState(0);
  const [result, setResult] = useState({ rows: [], total_count: 0 });
  const [loading, setLoading] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    supabase.rpc("get_phase7_audit_history", {
      p_page: page,
      p_start_date: filters.start || null,
      p_end_date: filters.end || null,
      p_actor: filters.actor || null,
      p_event_type: filters.event || null,
      p_search: filters.search || null,
      p_export: false,
    }).then(({ data, error: historyError }) => {
      if (!active) return;
      if (historyError) throw historyError;
      setResult(data || { rows: [], total_count: 0 });
    }).catch((loadError) => {
      console.error("Audit history could not be loaded:", loadError);
      if (active) setError("Audit history is unavailable right now.");
    }).finally(() => {
      if (active) setLoading(false);
    });
    return () => { active = false; };
  }, [supabase, page, filters]);

  function updateFilter(key, value) {
    setFilters((current) => ({ ...current, [key]: value }));
    setPage(0);
  }

  async function exportHistory() {
    setExporting(true);
    setError("");
    setNotice("");
    try {
      const { data, error: exportError } = await supabase.rpc("get_phase7_audit_history", {
        p_page: 0,
        p_start_date: filters.start || null,
        p_end_date: filters.end || null,
        p_actor: filters.actor || null,
        p_event_type: filters.event || null,
        p_search: filters.search || null,
        p_export: true,
      });
      if (exportError) throw exportError;
      const rows = data.rows || [];
      const values = rows.map((row) => [formatManilaDateTime(row.event_time), row.actor_id, row.event_type, row.entity_type,
        row.entity_id, row.source_table || row.source, JSON.stringify(row.before_values), JSON.stringify(row.after_values)]);
      downloadCsv("rmmc-audit-history.csv", [AUDIT_HEADERS, ...values]);
      setNotice(data.truncated
        ? `Export capped at 5,000 rows. ${data.total_count - 5000} additional rows were not included.`
        : `Audit export downloaded (${rows.length} rows).`);
    } catch (exportError) {
      console.error("The audit export could not be created:", exportError);
      setError("The audit export could not be created. Please try again.");
    } finally {
      setExporting(false);
    }
  }

  return (
    <div className="phase7-workspace">
      <div className="phase7-section-heading">
        <div><h2>Audit log</h2><p>{isAdmin ? "Canonical events and read-only legacy history." : "Borrowing-related audit events."}</p></div>
        <div className="phase7-export-control">
          <button className="button-secondary" type="button" title="This file contains personal data. Handle it accordingly."
            onClick={exportHistory} disabled={loading || exporting}>
            <Download size={14} /> {exporting ? "Preparing…" : "Export CSV"}
          </button>
          <small>Contains personal data. Handle accordingly.</small>
        </div>
      </div>
      <div className="phase7-audit-filters">
        <label><span>From</span><input type="date" value={filters.start} onChange={(event) => updateFilter("start", event.target.value)} /></label>
        <label><span>Through</span><input type="date" value={filters.end} onChange={(event) => updateFilter("end", event.target.value)} /></label>
        {isAdmin && <label><span>Actor ID</span><input value={filters.actor} onChange={(event) => updateFilter("actor", event.target.value)} placeholder="UUID" /></label>}
        <label><span>Event type</span><input value={filters.event} onChange={(event) => updateFilter("event", event.target.value)} placeholder="Filter events" /></label>
        <label className="phase7-audit-search"><span>Search history</span><div className="search-box"><Search size={15} /><input value={filters.search} onChange={(event) => updateFilter("search", event.target.value)} placeholder="Entity, ID, or value" /></div></label>
      </div>
      {error && <p className="feedback feedback-error" role="alert">{error}</p>}
      {notice && <p className="feedback feedback-success" role="status">{notice}</p>}
      {loading ? <p className="phase7-empty">Loading audit history…</p> : !result.rows?.length
        ? <p className="phase7-empty">No audit events match these filters.</p>
        : <div className="audit-list phase7-audit-list">{result.rows.map((row, index) => (
          <article className="audit-entry" key={`${row.source_table}-${row.entity_id}-${row.event_time}-${index}`}>
            <span className="audit-mark audit-update"><Search size={15} /></span>
            <div className="audit-entry-main">
              <strong>{row.event_type?.replaceAll("_", " ")}</strong>
              <p>{row.entity_type} · {row.entity_id || "—"} · {row.source_table || row.source}</p>
              <small>{formatManilaDateTime(row.event_time)} · Actor {row.actor_id || "unknown"}</small>
              {(row.before_values || row.after_values) && <details>
                <summary>Show recorded values</summary>
                <div className="audit-values">
                  {row.before_values && <div><b>Before</b><pre>{JSON.stringify(row.before_values, null, 2)}</pre></div>}
                  {row.after_values && <div><b>After</b><pre>{JSON.stringify(row.after_values, null, 2)}</pre></div>}
                </div>
              </details>}
            </div>
          </article>
        ))}</div>}
      <nav className="phase7-pagination" aria-label="Audit history pages">
        <span>Page {page + 1} · {result.total_count || 0} events</span>
        <div>
          <button className="button-icon" type="button" aria-label="Previous page" title="Previous page" onClick={() => setPage((current) => Math.max(0, current - 1))} disabled={page === 0}><ArrowLeft size={15} /></button>
          <button className="button-icon" type="button" aria-label="Next page" title="Next page" onClick={() => setPage((current) => current + 1)} disabled={(page + 1) * 20 >= (result.total_count || 0)}><ArrowRight size={15} /></button>
        </div>
      </nav>
    </div>
  );
}
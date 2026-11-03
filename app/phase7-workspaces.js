"use client";

import { useEffect, useState } from "react";
import { ArrowLeft, ArrowRight, Download, Search } from "lucide-react";
import { downloadCsv } from "@/lib/csv.mjs";

const REPORT_TYPES = [
  { id: "utilization", title: "Utilization", description: "Borrowed unit-days against available unit-days." },
  { id: "most_borrowed", title: "Most borrowed", description: "Top 20 equipment by borrowing count." },
  { id: "overdue", title: "Overdue", description: "Current overdue items grouped by equipment and borrower." },
  { id: "damage_loss", title: "Damage and loss", description: "Reported units grouped by resolution status and equipment." },
];

function dateValue(date) {
  return date.toISOString().slice(0, 10);
}

function initialStartDate() {
  const start = new Date();
  start.setDate(start.getDate() - 29);
  return dateValue(start);
}

export function ReportsWorkspace({ supabase }) {
  const [startDate, setStartDate] = useState(initialStartDate);
  const [endDate, setEndDate] = useState(() => dateValue(new Date()));
  const [pages, setPages] = useState({});
  const [reports, setReports] = useState({});
  const [loading, setLoading] = useState(false);
  const [exporting, setExporting] = useState("");
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");

  useEffect(() => {
    let active = true;
    setLoading(true);
    setError("");
    Promise.all(REPORT_TYPES.map(async (report) => {
      const { data, error: reportError } = await supabase.rpc("get_phase7_report", {
        p_report_type: report.id,
        p_start_date: startDate || null,
        p_end_date: endDate || null,
        p_page: pages[report.id] || 0,
        p_export: false,
      });
      if (reportError) throw reportError;
      return [report.id, data];
    })).then((entries) => {
      if (active) setReports(Object.fromEntries(entries));
    }).catch((loadError) => {
      if (active) setError(loadError.message || "Reports could not be loaded.");
    }).finally(() => {
      if (active) setLoading(false);
    });
    return () => { active = false; };
  }, [supabase, startDate, endDate, pages]);

  async function exportReport(report) {
    setExporting(report.id);
    setError("");
    setNotice("");
    try {
      const { data, error: exportError } = await supabase.rpc("get_phase7_report", {
        p_report_type: report.id,
        p_start_date: startDate || null,
        p_end_date: endDate || null,
        p_page: 0,
        p_export: true,
      });
      if (exportError) throw exportError;
      downloadCsv(`rmmc-${report.id}-${startDate}-${endDate}.csv`, [data.headers, ...data.rows]);
      setNotice(data.truncated
        ? `Export capped at 5,000 rows. ${data.total_count - 5000} additional rows were not included.`
        : `${report.title} export downloaded (${data.rows.length} rows).`);
    } catch (exportError) {
      setError(exportError.message || "The report export could not be created.");
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
      {error && <p className="feedback feedback-error" role="alert">{error}</p>}
      {notice && <p className="feedback feedback-success" role="status">{notice}</p>}
      {REPORT_TYPES.map((report) => {
        const result = reports[report.id];
        const rows = result?.rows || [];
        const maxBorrowings = report.id === "most_borrowed"
          ? Math.max(1, ...rows.map((row) => Number(row[2] || 0)))
          : 1;
        return (
          <section className="phase7-report" key={report.id}>
            <div className="phase7-section-heading">
              <div><h2>{report.title}</h2><p>{report.description}</p></div>
              <div className="phase7-export-control">
                <button className="button-secondary" type="button" title="This file contains personal data. Handle it accordingly."
                  onClick={() => exportReport(report)} disabled={loading || Boolean(exporting)}>
                  <Download size={14} /> {exporting === report.id ? "Preparing…" : "Export CSV"}
                </button>
                <small>Contains personal data. Handle accordingly.</small>
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
      if (active) setError(loadError.message || "Audit history could not be loaded.");
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
      const values = rows.map((row) => [row.event_time, row.actor_id, row.event_type, row.entity_type,
        row.entity_id, row.source_table || row.source, JSON.stringify(row.before_values), JSON.stringify(row.after_values)]);
      downloadCsv("rmmc-audit-history.csv", [AUDIT_HEADERS, ...values]);
      setNotice(data.truncated
        ? `Export capped at 5,000 rows. ${data.total_count - 5000} additional rows were not included.`
        : `Audit export downloaded (${rows.length} rows).`);
    } catch (exportError) {
      setError(exportError.message || "The audit export could not be created.");
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
              <small>{new Date(row.event_time).toLocaleString()} · Actor {row.actor_id || "unknown"}</small>
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
"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import Papa from "papaparse";
import { QRCodeSVG } from "qrcode.react";
import { ArrowLeft, ArrowRight, Check, Download, Printer, Search, Upload, X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";

const CSV_TEMPLATE = "asset_code,equipment_name,category_name,tracking_mode,quantity,unit_asset_tag,serial_number,unit_status,notes,calibration_due_at\nCAM-001,Canon camera,General,unit,2,CAM-001-A,SERIAL-001,available,,\nCAM-001,Canon camera,General,unit,2,CAM-001-B,SERIAL-002,available,,\n";

const localTimestamp = () => {
  const date = new Date(Date.now() - new Date().getTimezoneOffset() * 60000);
  return date.toISOString().slice(0, 16);
};

export default function EquipmentUnitsPage() {
  const [supabase, setSupabase] = useState(null);
  const [units, setUnits] = useState([]);
  const [equipmentCandidates, setEquipmentCandidates] = useState([]);
  const [dueUnits, setDueUnits] = useState([]);
  const [candidateSearch, setCandidateSearch] = useState("");
  const [conversionEquipmentId, setConversionEquipmentId] = useState("");
  const [conversionText, setConversionText] = useState("");
  const [conversionRows, setConversionRows] = useState([]);
  const [conversionError, setConversionError] = useState("");
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState("all");
  const [pageCursors, setPageCursors] = useState([0]);
  const [pageIndex, setPageIndex] = useState(0);
  const [selected, setSelected] = useState(new Map());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [maintenance, setMaintenance] = useState(null);
  const [importRows, setImportRows] = useState(null);
  const [importResults, setImportResults] = useState([]);
  const [importFileName, setImportFileName] = useState("");
  const [refreshKey, setRefreshKey] = useState(0);
  const cursor = pageCursors[pageIndex] || 0;

  useEffect(() => {
    try {
      setSupabase(createClient());
    } catch (clientError) {
      setError(clientError.message);
    }
  }, []);

  useEffect(() => {
    if (!supabase) return undefined;
    let active = true;
    supabase.rpc("search_equipment_units_page", {
      p_search: query.trim() || null,
      p_status: statusFilter === "all" ? null : statusFilter,
      p_after_unit_id: cursor,
    }).then(({ data, error: resultError }) => {
      if (!active) return;
      if (resultError) {
        setError(resultError.message);
        setUnits([]);
      } else {
        setUnits(data || []);
        setError("");
      }
    });
    return () => { active = false; };
  }, [supabase, query, statusFilter, cursor, refreshKey]);

  useEffect(() => {
    if (!supabase) return undefined;
    let active = true;
    supabase.rpc("search_equipment_page", {
      p_search: candidateSearch.trim() || null,
      p_category_id: null,
      p_after_name: null,
      p_after_id: null,
    }).then(({ data, error: resultError }) => {
      if (!active) return;
      if (resultError) setError(resultError.message);
      else setEquipmentCandidates((data || []).filter((equipment) => equipment.tracking_mode === "quantity"));
    });
    return () => { active = false; };
  }, [supabase, candidateSearch, refreshKey]);

  useEffect(() => {
    if (!supabase) return undefined;
    let active = true;
    supabase.rpc("equipment_units_due_for_calibration", { p_days: 14 }).then(({ data, error: resultError }) => {
      if (!active) return;
      if (!resultError) setDueUnits(data || []);
    });
    return () => { active = false; };
  }, [supabase, refreshKey]);

  const selectedUnits = useMemo(() => [...selected.values()], [selected]);

  function updateSearch(value) {
    setQuery(value);
    setPageCursors([0]);
    setPageIndex(0);
  }

  function goNext() {
    if (units.length < 20) return;
    const nextCursor = units[units.length - 1].unit_id;
    setPageCursors((cursors) => [...cursors.slice(0, pageIndex + 1), nextCursor]);
    setPageIndex((index) => index + 1);
  }

  function goPrevious() {
    if (pageIndex === 0) return;
    setPageIndex((index) => index - 1);
  }

  function toggleSelected(unit) {
    setSelected((current) => {
      const next = new Map(current);
      if (next.has(unit.unit_id)) next.delete(unit.unit_id);
      else next.set(unit.unit_id, unit);
      return next;
    });
  }

  async function saveStatus(unit, nextStatus, reason = "", expectedBackAt = null) {
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const { error: rpcError } = await supabase.rpc("set_equipment_unit_status", {
        p_unit_id: unit.unit_id,
        p_status: nextStatus,
        p_reason: reason || null,
        p_started_at: nextStatus === "maintenance" ? localTimestamp() : null,
        p_expected_back_at: expectedBackAt || null,
      });
      if (rpcError) throw rpcError;
      setMaintenance(null);
      setNotice(`Unit ${unit.asset_tag} marked ${nextStatus.replaceAll("_", " ")}.`);
      setRefreshKey((key) => key + 1);
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusy(false);
    }
  }

  async function saveCalibration(unit, event) {
    event.preventDefault();
    const dueDate = new FormData(event.currentTarget).get("calibration_due_at") || null;
    setBusy(true);
    try {
      const { error: rpcError } = await supabase.rpc("set_equipment_unit_calibration_due", {
        p_unit_id: unit.unit_id,
        p_due_date: dueDate,
      });
      if (rpcError) throw rpcError;
      setNotice(`Calibration date saved for ${unit.asset_tag}.`);
      setRefreshKey((key) => key + 1);
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusy(false);
    }
  }

  async function readImportFile(event) {
    const file = event.target.files?.[0];
    setImportRows(null);
    setImportResults([]);
    setError("");
    setNotice("");
    if (!file) return;
    if (file.size > 1024 * 1024) {
      setError("CSV files must be 1 MB or smaller.");
      event.target.value = "";
      return;
    }
    Papa.parse(file, {
      header: true,
      skipEmptyLines: true,
      transformHeader: (header) => header.trim().toLowerCase(),
      complete: (result) => {
        if (result.errors.length) {
          setError(`CSV parsing failed on line ${result.errors[0].row + 2}: ${result.errors[0].message}`);
          return;
        }
        if (result.data.length > 500) {
          setError("CSV files may contain at most 500 rows.");
          return;
        }
        setImportRows(result.data);
        setImportFileName(file.name);
      },
    });
    event.target.value = "";
  }

  async function previewImport() {
    if (!importRows?.length) return;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const { data, error: rpcError } = await supabase.rpc("import_equipment_csv", {
        p_rows: importRows,
        p_dry_run: true,
      });
      if (rpcError) throw rpcError;
      setImportResults(data?.rows || []);
      setNotice(data?.ok ? `${importRows.length} rows passed validation.` : "Review the row errors before importing.");
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusy(false);
    }
  }

  function previewConversion() {
    setConversionError("");
    const equipment = equipmentCandidates.find((item) => String(item.equipment_id) === conversionEquipmentId);
    if (!equipment) {
      setConversionError("Choose quantity-tracked equipment to convert.");
      return;
    }
    if (new Blob([conversionText]).size > 1024 * 1024) {
      setConversionError("Unit tag lists must be 1 MB or smaller.");
      return;
    }
    const result = Papa.parse(conversionText, { skipEmptyLines: true });
    if (result.errors.length) {
      setConversionError(`Could not parse unit list: ${result.errors[0].message}`);
      return;
    }
    if (result.data.length > 10000) {
      setConversionError("Unit tag lists may contain at most 10,000 rows.");
      return;
    }
    const rows = result.data.map((row) => ({
      asset_tag: String(row[0] || "").trim(),
      serial_number: String(row[1] || "").trim() || null,
      status: String(row[2] || "available").trim() || "available",
      notes: String(row[3] || "").trim() || null,
      calibration_due_at: String(row[4] || "").trim() || null,
    }));
    const activeCount = rows.filter((row) => row.status !== "retired").length;
    const maintenanceCount = rows.filter((row) => row.status === "maintenance").length;
    const duplicateTags = rows.some((row, index) => rows.findIndex((other) => other.asset_tag === row.asset_tag) !== index);
    if (activeCount !== equipment.quantity || maintenanceCount !== equipment.out_of_service_quantity || duplicateTags || rows.some((row) => !row.asset_tag)) {
      setConversionError(`Expected ${equipment.quantity} non-retired units and ${equipment.out_of_service_quantity} maintenance units, with unique non-empty asset tags.`);
      setConversionRows([]);
      return;
    }
    setConversionRows(rows);
  }

  async function convertEquipment() {
    if (!conversionRows.length) return;
    setBusy(true);
    setConversionError("");
    try {
      const { error: rpcError } = await supabase.rpc("convert_equipment_to_unit_tracking", {
        p_equipment_id: Number(conversionEquipmentId),
        p_units: conversionRows,
      });
      if (rpcError) throw rpcError;
      setNotice("Equipment converted to unit tracking.");
      setConversionText("");
      setConversionRows([]);
      setConversionEquipmentId("");
      setRefreshKey((key) => key + 1);
    } catch (actionError) {
      setConversionError(actionError.message);
    } finally {
      setBusy(false);
    }
  }

  async function commitImport() {
    if (!importRows?.length || importResults.length !== importRows.length || importResults.some((row) => !row.valid)) return;
    setBusy(true);
    setError("");
    setNotice("");
    try {
      const { data, error: rpcError } = await supabase.rpc("import_equipment_csv", {
        p_rows: importRows,
        p_dry_run: false,
      });
      if (rpcError) throw rpcError;
      if (!data?.ok) {
        setImportResults(data?.rows || []);
        throw new Error("The import was rejected. No equipment was saved.");
      }
      setNotice(`${data.imported_rows} CSV rows imported successfully.`);
      setImportRows(null);
      setImportResults([]);
      setImportFileName("");
      setRefreshKey((key) => key + 1);
    } catch (actionError) {
      setError(actionError.message);
    } finally {
      setBusy(false);
    }
  }

  function downloadTemplate() {
    const url = URL.createObjectURL(new Blob([CSV_TEMPLATE], { type: "text/csv;charset=utf-8" }));
    const link = document.createElement("a");
    link.href = url;
    link.download = "equipment-units-template.csv";
    link.click();
    URL.revokeObjectURL(url);
  }

  function printLabels() {
    if (!selectedUnits.length) return;
    window.print();
  }

  return (
    <main className="inventory-tool-page">
      <header className="inventory-tool-header no-print">
        <Link href="/" className="button-secondary"><ArrowLeft size={15} /> Workspace</Link>
        <div><p className="eyebrow">Inventory operations</p><h1>Equipment units</h1></div>
        <button className="button-primary" type="button" onClick={printLabels} disabled={!selectedUnits.length}><Printer size={15} /> Print labels ({selectedUnits.length})</button>
      </header>
      {(error || notice) && <p className={`feedback ${error ? "feedback-error" : "feedback-success"} no-print`} role={error ? "alert" : "status"}>{error || notice}</p>}

      <section className="unit-toolbar no-print">
        <label className="search-box"><Search size={17} /><input value={query} onChange={(event) => updateSearch(event.target.value)} placeholder="Search tag, serial, or equipment" aria-label="Search equipment units" /></label>
        <select value={statusFilter} onChange={(event) => { setStatusFilter(event.target.value); setPageCursors([0]); setPageIndex(0); }} aria-label="Filter by unit status">
          <option value="all">All statuses</option><option value="available">Available</option><option value="borrowed">Borrowed</option><option value="maintenance">Maintenance</option><option value="lost">Lost</option><option value="retired">Retired</option>
        </select>
        <button className="button-secondary" type="button" onClick={downloadTemplate}><Download size={15} /> CSV template</button>
        <label className="button-secondary file-button"><Upload size={15} /> Import CSV<input type="file" accept=".csv,text/csv" onChange={readImportFile} /></label>
      </section>

      <section className="unit-import-section no-print">
        <div className="unit-import-heading"><div><h2>Bulk import</h2><p>{importFileName || "CSV, up to 1 MB and 500 rows"}</p></div>
          <div className="table-actions"><button className="button-secondary" type="button" onClick={previewImport} disabled={busy || !importRows?.length}>Preview</button><button className="button-primary" type="button" onClick={commitImport} disabled={busy || !importRows?.length || importResults.length !== importRows.length || importResults.some((row) => !row.valid)}>Import</button></div>
        </div>
        {importResults.length > 0 && <div className="unit-import-results" role="status">{importResults.map((row) => <p key={row.line} className={row.valid ? "import-row-valid" : "import-row-invalid"}><strong>Line {row.line}</strong> {row.valid ? "Valid" : row.errors.join(" ")}</p>)}</div>}
      </section>

      <section className="unit-import-section no-print">
        <div className="unit-import-heading"><div><h2>Convert existing equipment</h2><p>Keep its current quantity and out-of-service count; add one CSV row per unit.</p></div></div>
        <div className="unit-conversion-form">
          <label><span>Find equipment</span><input value={candidateSearch} onChange={(event) => { setCandidateSearch(event.target.value); setConversionRows([]); }} placeholder="Search quantity-tracked equipment" /></label>
          <label><span>Equipment</span><select value={conversionEquipmentId} onChange={(event) => { setConversionEquipmentId(event.target.value); setConversionRows([]); }}><option value="">Select equipment</option>{equipmentCandidates.map((equipment) => <option key={equipment.equipment_id} value={equipment.equipment_id}>{equipment.equipment_name} · {equipment.quantity} total · {equipment.out_of_service_quantity} maintenance</option>)}</select></label>
          <label><span>Unit rows (asset tag, serial, status, notes, calibration date)</span><textarea rows="4" value={conversionText} onChange={(event) => { setConversionText(event.target.value); setConversionRows([]); }} placeholder={'CAM-001-A,SERIAL-001,available,,\nCAM-001-B,SERIAL-002,maintenance,Needs repair,2026-11-20'} /></label>
          {conversionError && <p className="feedback feedback-error" role="alert">{conversionError}</p>}
          {conversionRows.length > 0 && <p className="feedback feedback-success" role="status">{conversionRows.length} unit rows ready for conversion.</p>}
          <div className="table-actions"><button className="button-secondary" type="button" onClick={previewConversion} disabled={!conversionText.trim()}>Preview unit rows</button><button className="button-primary" type="button" onClick={convertEquipment} disabled={busy || !conversionRows.length}>{busy ? "Converting…" : "Convert to unit tracking"}</button></div>
        </div>
      </section>

      <div className="table-wrap inventory-table no-print">
        <table><thead><tr><th><span className="sr-only">Select label</span></th><th>Unit</th><th>Serial</th><th>Status</th><th>Maintenance / due</th><th>Calibration due</th><th>Actions</th></tr></thead>
          <tbody>{units.map((unit) => <tr key={unit.unit_id}>
            <td><input type="checkbox" checked={selected.has(unit.unit_id)} onChange={() => toggleSelected(unit)} aria-label={`Select label for ${unit.asset_tag}`} /></td>
            <td><strong>{unit.equipment_name}</strong><small>{unit.asset_tag}</small></td>
            <td>{unit.serial_number || "—"}</td>
            <td><span className={`pill pill-${unit.status}`}>{unit.status.replaceAll("_", " ")}</span></td>
            <td>{unit.expected_back_at ? new Date(unit.expected_back_at).toLocaleDateString() : "—"}</td>
            <td><form className="unit-calibration-form" onSubmit={(event) => saveCalibration(unit, event)}><input type="date" name="calibration_due_at" defaultValue={unit.calibration_due_at || ""} aria-label={`Calibration due date for ${unit.asset_tag}`} /><button className="button-secondary" type="submit" disabled={busy}>Save</button></form></td>
            <td><div className="table-actions">
              {unit.status === "available" && <button className="button-secondary" type="button" disabled={busy} onClick={() => setMaintenance({ unit, reason: "", expected: "" })}>Maintenance</button>}
              {unit.status === "maintenance" && <button className="button-primary" type="button" disabled={busy} onClick={() => saveStatus(unit, "available")}>Mark available</button>}
              {unit.status === "available" && <button className="button-danger" type="button" disabled={busy} onClick={() => saveStatus(unit, "retired")}>Retire</button>}
            </div></td>
          </tr>)}</tbody>
        </table>
        {!units.length && <p className="unit-empty">No units match this search.</p>}
      </div>
      <nav className="unit-pagination no-print" aria-label="Unit pages"><span>Page {pageIndex + 1} · {units.length} units</span><div><button className="button-secondary" type="button" onClick={goPrevious} disabled={pageIndex === 0}><ArrowLeft size={14} /> Previous</button><button className="button-secondary" type="button" onClick={goNext} disabled={units.length < 20}>Next <ArrowRight size={14} /></button></div></nav>

      <section className="unit-import-section no-print">
        <div className="unit-import-heading"><div><h2>Calibration due soon</h2><p>Units with an inspection or calibration date in the next 14 days</p></div><span className="record-count">{dueUnits.length} units</span></div>
        {dueUnits.length > 0 && <div className="table-wrap inventory-table"><table><thead><tr><th>Unit</th><th>Equipment</th><th>Due</th><th>Status</th></tr></thead><tbody>{dueUnits.map((unit) => <tr key={unit.unit_id}><td>{unit.asset_tag}</td><td>{unit.equipment_id}</td><td>{unit.calibration_due_at}</td><td>{unit.status}</td></tr>)}</tbody></table></div>}
      </section>

      {maintenance && <div className="modal-wrap no-print">
        <button className="modal-backdrop" type="button" onClick={() => setMaintenance(null)} aria-label="Close maintenance form" />
        <section className="modal" role="dialog" aria-modal="true" aria-labelledby="maintenance-title">
          <div className="modal-kicker">UNIT MAINTENANCE</div><h2 id="maintenance-title">Schedule maintenance</h2><p className="modal-copy">{maintenance.unit.asset_tag} · {maintenance.unit.equipment_name}</p>
          <form className="modal-form" onSubmit={(event) => { event.preventDefault(); saveStatus(maintenance.unit, "maintenance", maintenance.reason, maintenance.expected ? new Date(maintenance.expected).toISOString() : null); }}>
            <label><span>Reason</span><textarea rows="3" maxLength={1000} value={maintenance.reason} onChange={(event) => setMaintenance({ ...maintenance, reason: event.target.value })} required /></label>
            <label><span>Expected back</span><input type="datetime-local" value={maintenance.expected} onChange={(event) => setMaintenance({ ...maintenance, expected: event.target.value })} /></label>
            <div className="modal-actions"><button type="button" className="button-secondary" onClick={() => setMaintenance(null)}>Cancel</button><button type="submit" className="button-primary" disabled={busy || !maintenance.reason.trim()}>{busy ? "Saving…" : "Start maintenance"} <Check size={15} /></button></div>
          </form>
        </section>
      </div>}

      <section className="unit-label-sheet print-only" aria-label="Equipment unit labels">
        {selectedUnits.map((unit) => <article className="unit-label" key={unit.unit_id}><QRCodeSVG value={unit.asset_tag} size={120} level="M" includeMargin /><strong>{unit.asset_tag}</strong></article>)}
      </section>
    </main>
  );
}

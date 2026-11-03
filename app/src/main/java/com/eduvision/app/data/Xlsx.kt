package com.eduvision.app.data

import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.InputStream
import java.io.OutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/**
 * Minimal .xlsx support: write one sheet of strings and numbers, read the
 * first sheet of a workbook as text. Enough for the results export and the
 * class-roster import, without pulling a spreadsheet library into the APK.
 */
object Xlsx {
    sealed interface Cell
    data class Text(val value: String) : Cell
    data class Num(val value: Number) : Cell

    fun write(out: OutputStream, sheetName: String, rows: List<List<Cell>>) {
        ZipOutputStream(out).use { zip ->
            fun put(name: String, body: String) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(body.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
            put("[Content_Types].xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>""")
            put("_rels/.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>""")
            put("xl/workbook.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
<sheets><sheet name="${esc(sheetName)}" sheetId="1" r:id="rId1"/></sheets>
</workbook>""")
            put("xl/_rels/workbook.xml.rels", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>""")
            // Style 1: bold header row.
            put("xl/styles.xml", """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts>
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>
</styleSheet>""")
            val sb = StringBuilder()
            sb.append("""<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>""")
            rows.forEachIndexed { r, row ->
                sb.append("<row r=\"${r + 1}\">")
                row.forEachIndexed { c, cell ->
                    val ref = column(c) + (r + 1)
                    val style = if (r == 0) " s=\"1\"" else ""
                    when (cell) {
                        is Text -> sb.append("<c r=\"$ref\" t=\"inlineStr\"$style><is><t xml:space=\"preserve\">${esc(cell.value)}</t></is></c>")
                        is Num -> sb.append("<c r=\"$ref\"$style><v>${cell.value}</v></c>")
                    }
                }
                sb.append("</row>")
            }
            sb.append("</sheetData></worksheet>")
            put("xl/worksheets/sheet1.xml", sb.toString())
        }
    }

    /** The first worksheet as rows of cell text (shared, inline and plain values). */
    fun readFirstSheet(input: InputStream): List<List<String>> {
        val files = HashMap<String, ByteArray>()
        ZipInputStream(input).use { zip ->
            while (true) {
                val e = zip.nextEntry ?: break
                if (e.name == "xl/sharedStrings.xml" || e.name.startsWith("xl/worksheets/sheet") || e.name == "xl/workbook.xml" ||
                    e.name == "xl/_rels/workbook.xml.rels") {
                    files[e.name] = zip.readBytes()
                }
            }
        }
        val shared = files["xl/sharedStrings.xml"]?.let(::parseShared).orEmpty()
        val sheetPath = firstSheetPath(files) ?: files.keys.filter { it.startsWith("xl/worksheets/sheet") }.minOrNull() ?: return emptyList()
        return parseSheet(files[sheetPath] ?: return emptyList(), shared)
    }

    private fun firstSheetPath(files: Map<String, ByteArray>): String? {
        val wb = files["xl/workbook.xml"] ?: return null
        val rels = files["xl/_rels/workbook.xml.rels"] ?: return null
        var rid: String? = null
        parse(wb) { p -> if (p.eventType == XmlPullParser.START_TAG && p.name == "sheet" && rid == null) rid = p.getAttributeValue(null, "r:id") ?: (0 until p.attributeCount).firstOrNull { p.getAttributeName(it).endsWith("id") && p.getAttributeName(it) != "sheetId" }?.let(p::getAttributeValue) }
        var target: String? = null
        parse(rels) { p -> if (p.eventType == XmlPullParser.START_TAG && p.name == "Relationship" && p.getAttributeValue(null, "Id") == rid) target = p.getAttributeValue(null, "Target") }
        return target?.let { if (it.startsWith("/")) it.drop(1) else "xl/$it" }
    }

    private fun parseShared(bytes: ByteArray): List<String> {
        val out = ArrayList<String>()
        val cur = StringBuilder()
        var inT = false
        parse(bytes) { p ->
            when (p.eventType) {
                XmlPullParser.START_TAG -> when (p.name) { "si" -> cur.clear(); "t" -> inT = true }
                XmlPullParser.TEXT -> if (inT) cur.append(p.text)
                XmlPullParser.END_TAG -> when (p.name) { "t" -> inT = false; "si" -> out += cur.toString() }
            }
        }
        return out
    }

    private fun parseSheet(bytes: ByteArray, shared: List<String>): List<List<String>> {
        val rows = ArrayList<List<String>>()
        var row = ArrayList<String>()
        var col = 0
        var type: String? = null
        val text = StringBuilder()
        var inValue = false
        parse(bytes) { p ->
            when (p.eventType) {
                XmlPullParser.START_TAG -> when (p.name) {
                    "row" -> row = ArrayList()
                    "c" -> {
                        type = p.getAttributeValue(null, "t")
                        col = p.getAttributeValue(null, "r")?.let(::columnIndex) ?: row.size
                        text.clear()
                    }
                    "v", "t" -> inValue = true
                }
                XmlPullParser.TEXT -> if (inValue) text.append(p.text)
                XmlPullParser.END_TAG -> when (p.name) {
                    "v", "t" -> inValue = false
                    "c" -> {
                        val raw = text.toString()
                        val value = if (type == "s") shared.getOrNull(raw.trim().toIntOrNull() ?: -1).orEmpty() else raw
                        while (row.size < col) row += ""
                        row += value.removeSuffix(".0")
                    }
                    "row" -> rows += row
                }
            }
        }
        return rows
    }

    private fun parse(bytes: ByteArray, onEvent: (XmlPullParser) -> Unit) {
        val p = Xml.newPullParser()
        p.setInput(bytes.inputStream(), "UTF-8")
        while (p.next() != XmlPullParser.END_DOCUMENT) onEvent(p)
    }

    private fun column(i: Int): String {
        var n = i + 1
        val sb = StringBuilder()
        while (n > 0) { val r = (n - 1) % 26; sb.insert(0, 'A' + r); n = (n - 1) / 26 }
        return sb.toString()
    }

    private fun columnIndex(ref: String): Int {
        var n = 0
        for (ch in ref) { if (!ch.isLetter()) break; n = n * 26 + (ch.uppercaseChar() - 'A' + 1) }
        return n - 1
    }

    private fun esc(s: String) = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")
}

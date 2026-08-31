function doPost(e) {
  const p = JSON.parse(e.postData.contents);

  const token = PropertiesService
    .getScriptProperties()
    .getProperty('API_TOKEN');

  if (!token || p.token !== token) {
    return ContentService
      .createTextOutput('Unauthorized');
  }

  const sheet = SpreadsheetApp
    .getActiveSpreadsheet()
    .getSheetByName(p.sheet);

  if (!sheet) {
    throw new Error(`Sheet not found: ${p.sheet}`);
  }

  const values = Utilities.parseCsv(p.data, '\t');
  const start = sheet.getRange(p.cell);

  const range = sheet.getRange(
    start.getRow(),
    start.getColumn(),
    values.length,
    values[0].length
  );

  range.setValues(values);

  const format = p.format;
  if (format && typeof format === 'object') {
    if (format.fontSize !== undefined && format.fontSize !== null) {
      range.setFontSize(Number(format.fontSize));
    }
    if (format.fontColor !== undefined && format.fontColor !== null) {
      range.setFontColor(format.fontColor);
    }
    if (format.backgroundColor !== undefined && format.backgroundColor !== null) {
      range.setBackground(format.backgroundColor);
    }
    if (format.fontWeight !== undefined && format.fontWeight !== null) {
      range.setFontWeight(format.fontWeight);
    }
    if (format.fontStyle !== undefined && format.fontStyle !== null) {
      range.setFontStyle(format.fontStyle);
    }
    if (format.fontFamily !== undefined && format.fontFamily !== null) {
      range.setFontFamily(format.fontFamily);
    }
    if (format.underline !== undefined && format.underline !== null) {
      range.setUnderline(format.underline === true || format.underline === 'true');
    }
    if (format.horizontalAlignment !== undefined && format.horizontalAlignment !== null) {
      range.setHorizontalAlignment(format.horizontalAlignment);
    }
    if (format.verticalAlignment !== undefined && format.verticalAlignment !== null) {
      range.setVerticalAlignment(format.verticalAlignment);
    }
    if (format.wrap !== undefined && format.wrap !== null) {
      range.setWrap(format.wrap === true || format.wrap === 'true');
    }
    if (format.numberFormat !== undefined && format.numberFormat !== null) {
      range.setNumberFormat(format.numberFormat);
    }
  }

  return ContentService.createTextOutput('OK');
}

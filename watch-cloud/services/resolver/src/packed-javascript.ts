const alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";

function matchingDelimiter(source: string, start: number, open: string, close: string): number {
  let depth = 1;
  let quote = "";
  let escaped = false;
  for (let index = start; index < source.length; index += 1) {
    const character = source[index] ?? "";
    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = "";
    } else if (character === "'" || character === '"') quote = character;
    else if (character === open) depth += 1;
    else if (character === close && --depth === 0) return index;
  }
  return -1;
}

function splitArguments(source: string): string[] {
  const values: string[] = [];
  let current = "";
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (const character of source) {
    if (quote) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === quote) quote = "";
    } else if (character === "'" || character === '"') quote = character;
    else if (character === "(") depth += 1;
    else if (character === ")") depth -= 1;
    else if (character === "," && depth === 0) {
      values.push(current);
      current = "";
      continue;
    }
    current += character;
  }
  values.push(current);
  return values;
}

function stringLiteral(source: string): string | undefined {
  const value = source.trim();
  const quote = value[0];
  if (quote !== "'" && quote !== '"') return undefined;
  let output = "";
  let escaped = false;
  for (let index = 1; index < value.length; index += 1) {
    const character = value[index] ?? "";
    if (escaped) {
      output += character === "n" ? "\n" : character === "r" ? "\r" : character === "t" ? "\t" : character;
      escaped = false;
    } else if (character === "\\") escaped = true;
    else if (character === quote) return output;
    else output += character;
  }
  return undefined;
}

function integerValue(token: string, radix: number): number | undefined {
  let value = 0;
  for (const character of token) {
    const digit = alphabet.indexOf(character);
    if (digit < 0 || digit >= radix) return undefined;
    value = value * radix + digit;
    if (!Number.isSafeInteger(value)) return undefined;
  }
  return value;
}

function unpack(payload: string, radix: number, count: number, dictionary: string): string {
  const words = dictionary.split("|");
  return payload.replace(/[0-9A-Za-z]+/g, (token) => {
    const index = integerValue(token, radix);
    return index !== undefined && index < count && words[index] ? words[index] : token;
  });
}

function decodePacked(value: string): string | undefined {
  const functionIndex = value.indexOf("function");
  if (functionIndex < 0) return undefined;
  const brace = value.indexOf("{", functionIndex);
  if (brace < 0) return undefined;
  const bodyEnd = matchingDelimiter(value, brace + 1, "{", "}");
  if (bodyEnd < 0) return undefined;
  const open = value.indexOf("(", bodyEnd + 1);
  if (open < 0) return undefined;
  const close = matchingDelimiter(value, open + 1, "(", ")");
  if (close < 0) return undefined;
  const parts = splitArguments(value.slice(open + 1, close));
  const payload = parts[0] ? stringLiteral(parts[0]) : undefined;
  const radix = Number(parts[1]?.trim());
  const count = Number(parts[2]?.trim());
  const dictionaryExpression = parts[3]?.split(".split")[0];
  const dictionary = dictionaryExpression ? stringLiteral(dictionaryExpression) : undefined;
  if (payload === undefined || dictionary === undefined || !Number.isInteger(radix) || radix < 2 || radix > 62 || !Number.isInteger(count) || count < 0) return undefined;
  return unpack(payload, radix, count, dictionary);
}

export function decodePackedJavaScript(source: string): string[] {
  const decoded: string[] = [];
  let offset = 0;
  while (true) {
    const evalIndex = source.indexOf("eval(", offset);
    if (evalIndex < 0) break;
    const start = evalIndex + 5;
    const end = matchingDelimiter(source, start, "(", ")");
    if (end > start) {
      const value = decodePacked(source.slice(start, end));
      if (value) decoded.push(value);
    }
    offset = evalIndex + 1;
  }
  return decoded;
}

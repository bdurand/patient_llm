// Simple markdown renderer for chat messages
const Markdown = {
  // Render markdown to HTML
  render(text) {
    if (!text) return '';

    let html = this.escapeHtml(text);

    // Code blocks (triple backticks) - process first to protect content
    const codeBlocks = [];
    html = html.replace(/```(\w*)\n([\s\S]*?)```/g, (match, lang, code) => {
      const placeholder = `__CODE_BLOCK_${codeBlocks.length}__`;
      const languageClass = lang ? ` class="language-${lang}"` : '';
      codeBlocks.push(`<pre><code${languageClass}>${code.trim()}</code></pre>`);
      return placeholder;
    });

    // Inline code (single backticks)
    html = html.replace(/`([^`]+)`/g, '<code>$1</code>');

    // Bold (double asterisks or underscores)
    html = html.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
    html = html.replace(/__([^_]+)__/g, '<strong>$1</strong>');

    // Italic (single asterisks or underscores)
    html = html.replace(/\*([^*]+)\*/g, '<em>$1</em>');
    html = html.replace(/(?<![_\w])_([^_]+)_(?![_\w])/g, '<em>$1</em>');

    // Strikethrough
    html = html.replace(/~~([^~]+)~~/g, '<del>$1</del>');

    // Headers (at start of line)
    html = html.replace(/^##### (.+)$/gm, '<h5>$1</h5>');
    html = html.replace(/^#### (.+)$/gm, '<h4>$1</h4>');
    html = html.replace(/^### (.+)$/gm, '<h3>$1</h3>');
    html = html.replace(/^## (.+)$/gm, '<h2>$1</h2>');
    html = html.replace(/^# (.+)$/gm, '<h1>$1</h1>');

    // Horizontal rule
    html = html.replace(/^---$/gm, '<hr>');

    // Blockquotes
    html = html.replace(/^&gt; (.+)$/gm, '<blockquote>$1</blockquote>');

    // Process tables
    html = this.processTables(html);

    // Process lists by splitting into lines
    html = this.processLists(html);

    // Links
    html = html.replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');

    // Line breaks (preserve newlines outside of code blocks)
    html = html.replace(/\n/g, '<br>');

    // Clean up breaks around block elements
    html = html.replace(/(<\/(pre|ul|ol|blockquote|h[1-5]|hr|li|table|tr|td|th|thead|tbody)>)<br>/g, '$1');
    html = html.replace(/<br>(<(pre|ul|ol|blockquote|h[1-5]|hr|li|table|thead|tbody|tr|td|th))/g, '$1');
    html = html.replace(/(<(table|thead|tbody|tr|td|th)[^>]*>)<br>/g, '$1');
    html = html.replace(/<br>(<\/(table|thead|tbody|tr|td|th)>)/g, '$1');

    // Restore code blocks
    codeBlocks.forEach((block, i) => {
      html = html.replace(`__CODE_BLOCK_${i}__`, block);
    });

    return html;
  },

  // Process unordered and ordered lists
  processLists(html) {
    const lines = html.split('\n');
    const result = [];
    let inUnorderedList = false;
    let inOrderedList = false;

    for (const line of lines) {
      const unorderedMatch = line.match(/^[-*] (.+)$/);
      const orderedMatch = line.match(/^\d+\. (.+)$/);

      if (unorderedMatch) {
        if (inOrderedList) {
          result.push('</ol>');
          inOrderedList = false;
        }
        if (!inUnorderedList) {
          result.push('<ul>');
          inUnorderedList = true;
        }
        result.push(`<li>${unorderedMatch[1]}</li>`);
      } else if (orderedMatch) {
        if (inUnorderedList) {
          result.push('</ul>');
          inUnorderedList = false;
        }
        if (!inOrderedList) {
          result.push('<ol>');
          inOrderedList = true;
        }
        result.push(`<li>${orderedMatch[1]}</li>`);
      } else {
        if (inUnorderedList) {
          result.push('</ul>');
          inUnorderedList = false;
        }
        if (inOrderedList) {
          result.push('</ol>');
          inOrderedList = false;
        }
        result.push(line);
      }
    }

    // Close any open lists
    if (inUnorderedList) result.push('</ul>');
    if (inOrderedList) result.push('</ol>');

    return result.join('\n');
  },

  // Process markdown tables
  processTables(html) {
    const lines = html.split('\n');
    const result = [];
    let tableLines = [];
    let inTable = false;

    for (const line of lines) {
      // Check if line looks like a table row (starts and ends with |, or has | separators)
      const isTableRow = /^\|.+\|$/.test(line.trim()) || /^\s*\|?[^|]+\|[^|]+/.test(line.trim());
      const isSeparator = /^\|?[\s:-]+\|[\s|:-]*$/.test(line.trim());

      if (isTableRow || isSeparator) {
        if (!inTable) {
          inTable = true;
          tableLines = [];
        }
        tableLines.push(line);
      } else {
        if (inTable) {
          // Process collected table lines
          result.push(this.buildTable(tableLines));
          inTable = false;
          tableLines = [];
        }
        result.push(line);
      }
    }

    // Handle table at end of content
    if (inTable && tableLines.length > 0) {
      result.push(this.buildTable(tableLines));
    }

    return result.join('\n');
  },

  // Build HTML table from markdown table lines
  buildTable(lines) {
    if (lines.length < 2) return lines.join('\n');

    // Parse cells from a row
    const parseCells = (line) => {
      return line
        .replace(/^\|\s*/, '')
        .replace(/\s*\|$/, '')
        .split('|')
        .map(cell => cell.trim());
    };

    // Find the separator line to determine header vs body
    let separatorIndex = -1;
    for (let i = 0; i < lines.length; i++) {
      if (/^\|?[\s:-]+\|[\s|:-]*$/.test(lines[i].trim())) {
        separatorIndex = i;
        break;
      }
    }

    let html = '<table>';

    if (separatorIndex > 0) {
      // Has header
      html += '<thead><tr>';
      const headerCells = parseCells(lines[0]);
      for (const cell of headerCells) {
        html += `<th>${cell}</th>`;
      }
      html += '</tr></thead>';

      // Body rows (skip separator)
      if (lines.length > separatorIndex + 1) {
        html += '<tbody>';
        for (let i = separatorIndex + 1; i < lines.length; i++) {
          const cells = parseCells(lines[i]);
          html += '<tr>';
          for (const cell of cells) {
            html += `<td>${cell}</td>`;
          }
          html += '</tr>';
        }
        html += '</tbody>';
      }
    } else {
      // No header, just body rows
      html += '<tbody>';
      for (const line of lines) {
        const cells = parseCells(line);
        html += '<tr>';
        for (const cell of cells) {
          html += `<td>${cell}</td>`;
        }
        html += '</tr>';
      }
      html += '</tbody>';
    }

    html += '</table>';
    return html;
  },

  // Escape HTML entities
  escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
  }
};

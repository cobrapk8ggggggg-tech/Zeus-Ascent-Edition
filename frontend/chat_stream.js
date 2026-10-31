function createStreamingMessage(sender = 'assistant') {
    const messageId = Date.now().toString();
    const messagesArea = document.getElementById('messagesArea');

    const messageDiv = document.createElement('div');
    messageDiv.className = `chat-bubble message-${sender} streaming-message`;
    messageDiv.id = `message-${messageId}`;

    messageDiv.innerHTML = `
        <div class="message-content" id="content-${messageId}">
            <span class="streaming-cursor"></span>
        </div>
        <div class="streaming-indicator">
            <i class="fas fa-robot text-xs"></i>
            <span>يكتب زيوس</span>
            <div class="streaming-dots">
                <div class="streaming-dot"></div>
                <div class="streaming-dot"></div>
                <div class="streaming-dot"></div>
            </div>
        </div>
    `;

    messagesArea.appendChild(messageDiv);
    scrollToBottom();

    streamingState.currentMessageId = messageId;
    streamingState.streamingElement = document.getElementById(`content-${messageId}`);
    streamingState.currentText = '';
    streamingState.isStreaming = true;
// ✨ الجديد: ثبت المحادثة التي بدأ فيها البث
    streamingState.chatId = currentChatId;

// زر الإرسال يتحول فوراً إلى "إيقاف"
    updateSendButton();

    return messageId;
}

function appendToStreamingMessage(text, isComplete = false) {
    if (!streamingState.isStreaming) return;

    // نجمع النص دائمًا
    streamingState.currentText += text;

    // إذا لم يكن لدينا عنصر DOM (مثلاً لأننا بدّلنا المحادثة)
    // ونعود الآن إلى نفس المحادثة التي يجري فيها البث،
    // نعيد إنشاء الفقاعة وربط العنصر مرة أخرى.
    if (!streamingState.streamingElement) {
        const weAreOnTheStreamingChat =
            currentChatId && streamingState.chatId && currentChatId === streamingState.chatId;

        if (weAreOnTheStreamingChat) {
            // إعادة إرفاق فقاعة البث في هذه المحادثة
            const messageId = streamingState.currentMessageId;
            const messagesArea = document.getElementById('messagesArea');

            // أنشئ غلاف الرسالة يدويًا (نسخة مبسطة من createStreamingMessage بدون إعادة ضبط الحالة)
            const messageDiv = document.createElement('div');
            messageDiv.className = `chat-bubble message-assistant streaming-message`;
            messageDiv.id = `message-${messageId}`;
            messageDiv.innerHTML = `
              <div class="message-content" id="content-${messageId}">
                  <span class="streaming-cursor"></span>
              </div>
              <div class="streaming-indicator">
                  <i class="fas fa-robot text-xs"></i>
                  <span>يكتب زيوس</span>
                  <div class="streaming-dots">
                      <div class="streaming-dot"></div>
                      <div class="streaming-dot"></div>
                      <div class="streaming-dot"></div>
                  </div>
              </div>
            `;
            messagesArea.appendChild(messageDiv);
            streamingState.streamingElement = document.getElementById(`content-${messageId}`);
        }
    }

    // إن لم يتوفر عنصر بعد (لأننا في محادثة أخرى)، نكتفي بتجميع النص ونؤجل العرض
    if (!streamingState.streamingElement) {
        if (isComplete) completeStreamingMessage();
        return;
    }

    // الآن نحدّث الـ DOM كالمعتاد
    const cursor = streamingState.streamingElement.querySelector('.streaming-cursor');
    if (cursor) cursor.remove();
    const renderedContent = marked.parse(streamingState.currentText);
    streamingState.streamingElement.innerHTML = renderedContent;

    if (!isComplete) {
        const newCursor = document.createElement('span');
        newCursor.className = 'streaming-cursor';
        streamingState.streamingElement.appendChild(newCursor);
    }

    streamingState.streamingElement.querySelectorAll('pre code').forEach(block => {
        hljs.highlightElement(block);
        addCodeHeader(block.parentElement);
    });

    smoothScrollToBottom();

    if (isComplete) {
        completeStreamingMessage();
    }
}

function completeStreamingMessage() {
  if (!streamingState.isStreaming) return;

  const messageElement = document.getElementById(`message-${streamingState.currentMessageId}`);
  if (messageElement) {
    // إزالة مؤشّر البث
    const indicator = messageElement.querySelector('.streaming-indicator');
    if (indicator) indicator.remove();
    messageElement.classList.remove('streaming-message');

    // --- جديد: استخراج قسم المصادر إن وجد ---
    // نبحث عن بادئة المصادر التي يرسلها الخادم: **🔍 المصادر:**
    const fullText = streamingState.currentText || '';
    const splitToken = '\n**🔍 المصادر:**\n';
    let mainText = fullText, sourcesMd = '';

    const idx = fullText.indexOf(splitToken);
    if (idx !== -1) {
      mainText  = fullText.slice(0, idx);
      sourcesMd = fullText.slice(idx + splitToken.length);
    }

    // إعادة عرض النص بدون قسم المصادر
    const contentEl = messageElement.querySelector('.message-content');
    if (contentEl) {
      contentEl.innerHTML = marked.parse(mainText);
      // تمييز الكود وإضافة رأس للكود كما في الباقي
      contentEl.querySelectorAll('pre code').forEach(block => {
        hljs.highlightElement(block);
        addCodeHeader(block.parentElement);
      });
    }

    // أزرار الرسالة (نسخ/إعادة توليد)
    addMessageActions(messageElement, mainText);

    // --- جديد: زر عرض/إخفاء المصادر إن توفّرت ---
    if (sourcesMd.trim()) {
      const sources = sourcesMd
        .split('\n')
        .map(l => l.trim())
        .filter(l => l.startsWith('- ['));

      if (sources.length > 0) {
        const wrapper = document.createElement('div');
        wrapper.className = 'mt-2';

        // زر تبديل
        const toggle = document.createElement('button');
        toggle.className = 'btn-custom btn-secondary sources-toggle';
        toggle.type = 'button';
        toggle.textContent = 'عرض المصادر';
        wrapper.appendChild(toggle);

        // قائمة المصادر (مخفية افتراضياً)
        const list = document.createElement('div');
        list.className = 'sources-list hidden';
        list.innerHTML = `
          <ul class="list-disc pr-6 mt-2 space-y-1 text-sm text-gray-300">
            ${sources.map(item => {
              // استخراج [العنوان](الرابط)
              const m = item.match(/\$begin:math:display$(.+?)\\$end:math:display$\$begin:math:text$(.+?)\\$end:math:text$/);
              if (!m) return '';
              const title = m[1], href = m[2];
              return `<li><a href="${href}" target="_blank" rel="noopener" class="underline hover:no-underline">${escapeHtml(title)}</a></li>`;
            }).join('')}
          </ul>
        `;
        wrapper.appendChild(list);

        toggle.addEventListener('click', () => {
          const isHidden = list.classList.contains('hidden');
          list.classList.toggle('hidden', !isHidden);
          toggle.textContent = isHidden ? 'إخفاء المصادر' : 'عرض المصادر';
        });

        messageElement.appendChild(wrapper);
      }
    }
  }

  // حفظ الرسالة في المحادثة الصحيحة (الكود الأصلي كما هو)
  const targetChatId = streamingState.chatId;
  if (targetChatId && chats[targetChatId] && (streamingState.currentText || '')) {
    const now = Date.now();
    chats[targetChatId].messages.push({ role: 'assistant', content: streamingState.currentText, timestamp: now });
    chats[targetChatId].updatedAt = now;
    chats[targetChatId].order = now;
  }

  // إعادة ضبط حالة البث
  streamingState.isStreaming = false;
  streamingState.currentMessageId = null;
  streamingState.streamingElement = null;
  streamingState.currentText = '';
  streamingState.streamController = null;
  streamingState.chatId = null;

  // حفظ المحادثة
  saveCurrentChat(targetChatId);
  scrollToBottom();
}

function smoothScrollToBottom() {
    const messagesArea = document.getElementById('messagesArea');
    messagesArea.scrollTo({
        top: messagesArea.scrollHeight,
        behavior: 'smooth'
    });
}

async function sendMessage() {

    if (streamingState.isStreaming) { 
        cancelStreaming('new-send'); 
        return; 
    }

    // ⚠️ في حال تغيّر المعرّف بعد حفظ سابق
    if (currentChatId && !chats[currentChatId]) {
        const latest = Object.values(chats).sort((a,b)=>(b.order||0)-(a.order||0))[0];
        currentChatId = latest ? latest._id : null;
    }

    const input = document.getElementById('messageInput');
    const sendButton = document.getElementById('sendButton');
    const fileInput = document.getElementById('fileInput');

    if (!input.value.trim() && fileInput.files.length === 0) return;

    const message = input.value.trim();
    const files = Array.from(fileInput.files);

    // The API key check is no longer needed on the frontend.
    // The backend will handle API key management.

    console.log('Sending message to backend with provider:', settings.provider, 'model:', settings.model);

    // Disable input during processing
    input.disabled = true;
    sendButton.disabled = true;

    try {
        // Create new chat if needed
        if (!currentChatId) {
            await startNewChat();
        }

        // ✨✨✨ الميزة الجديدة تبدأ هنا ✨✨✨
        // 1. تحقق إذا كانت هذه هي الرسالة الأولى في المحادثة الحالية
        if (chats[currentChatId] && chats[currentChatId].messages.length === 0 && message) {
            // 2. إذا كانت كذلك، قم بتحديث عنوان المحادثة
            chats[currentChatId].title = message;
            // 3. قم بتحديث قائمة المحادثات فورًا لإظهار الاسم الجديد
            displayChatHistory();
        }
        // ✨✨✨ الميزة الجديدة تنتهي هنا ✨✨✨

        // Process files if any
        let attachments = [];
        if (files.length > 0) {
            attachments = await processAttachedFiles(files);
        }

        // Create user message
        const userMessage = {
    role: 'user',
    content: message,
    attachments: attachments.map(file => ({
        name: file.name,
        size: file.size,
        type: file.type,
        fileId: file.fileId || null,
        fileUrl: file.fileUrl || null
    })),
    timestamp: Date.now()
};

        // Add user message to chat
        chats[currentChatId].messages.push(userMessage);

        // Display user message with file cards
        displayUserMessage(userMessage);

        // Scroll to show new message
        setTimeout(() => scrollToBottom(), 100);

        // Clear input
        input.value = '';
        clearFileInput();

        // Show welcome screen if hidden
        document.getElementById('welcomeScreen').classList.add('hidden');
        document.getElementById('messagesContainer').classList.remove('hidden');

// ... بعد إنشاء userMessage وعرضه
createStreamingMessage();

// (اختياري) لو المستخدم كتب جملة تبدأ بـ "ابحث عبر الانترنت" ولم نغيّر العتبة
if (settings.enableWebBrowsing && /^\\s*ابحث\\s+عبر\\s+الانترنت/i.test(message)) {
  // اجعل العتبة أقل قليلاً لتميل الأداة للبحث
  settings.dynamicThreshold = Math.max(0, Math.min(0.4, settings.dynamicThreshold || 0.6));
}

// Send to AI with streaming
await sendToAIWithStreaming(chats[currentChatId].messages, attachments);

    } catch (error) {
        console.error('Error sending message:', error);
        showNotification(`حدث خطأ: ${error.message}`, 'error');

        // Complete streaming message with error
        if (streamingState.isStreaming) {
            appendToStreamingMessage('\n\n❌ عذراً، حدث خطأ أثناء معالجة طلبك. يرجى المحاولة مرة أخرى.', true);
        }
    } finally {
        // Re-enable input
        input.disabled = false;
        sendButton.disabled = false;
        updateSendButton();
        input.focus();

        // Data will be saved when streaming completes
    }
}

function displayUserMessage(message) {
    const messagesArea = document.getElementById('messagesArea');
    const messageDiv = document.createElement('div');
    messageDiv.className = 'chat-bubble message-user';

    let content = `<div class="message-content">${escapeHtml(message.content)}</div>`;

    // Add file cards if there are attachments
    if (message.attachments && message.attachments.length > 0) {
        const fileCards = message.attachments.map(file => createFileCard(file)).join('');
        content += fileCards;
    }

    messageDiv.innerHTML = content;
    messagesArea.appendChild(messageDiv);
    scrollToBottom();
}

// ----------------------------------------------------------------------------------
// NEW: Functions to communicate with the local backend server
// ----------------------------------------------------------------------------------

async function sendToAIWithStreaming(chatHistory, attachments) {
  const lastUserMsg = (chatHistory || [])
    .slice().reverse().find(m => m.role === 'user')?.content || '';

  // البحث الذكي المتقدم - يحدد تلقائياً إذا كان المستخدم يريد البحث
  function shouldSearch(message) {
    const msg = message.toLowerCase().trim();
    
    // كلمات مفاتيح مباشرة للبحث
    const directSearchTerms = [
      'ابحث', 'بحث', 'البحث', 'تصفح', 'اعطني معلومات عن', 
      'ما هي آخر أخبار', 'آخر الأخبار', 'الأخبار الحديثة',
      'search', 'browse', 'find information', 'latest news', 'recent news'
    ];
    
    // مؤشرات على الحاجة لمعلومات حديثة
    const timeIndicators = [
      'اليوم', 'أمس', 'هذا الأسبوع', 'هذا الشهر', 'الآن', 'حالياً',
      'مؤخراً', 'جديد', 'حديث', 'متى', 'كم', 'أين',
      'today', 'yesterday', 'this week', 'this month', 'now', 'currently',
      'recently', 'new', 'recent', 'when', 'how much', 'where'
    ];
    
    // مواضيع تحتاج معلومات حديثة
    const currentTopics = [
      'سعر', 'أسعار', 'الأسهم', 'العملة', 'الطقس', 'الأخبار',
      'أحداث', 'تحديثات', 'إحصائيات', 'بيانات',
      'price', 'prices', 'stock', 'currency', 'weather', 'news',
      'events', 'updates', 'statistics', 'data'
    ];

    // فحص التطابقات المباشرة
    const hasDirectSearch = directSearchTerms.some(term => msg.includes(term));
    const hasTimeIndicator = timeIndicators.some(term => msg.includes(term));
    const hasCurrentTopic = currentTopics.some(term => msg.includes(term));
    
    // استخدام العتبة الديناميكية للحكم
    const threshold = settings.dynamicThreshold || 0.6;
    let searchScore = 0;
    
    if (hasDirectSearch) searchScore += 0.6;
    if (hasTimeIndicator) searchScore += 0.3;
    if (hasCurrentTopic) searchScore += 0.4;
    
    // أسئلة تحتاج معلومات حديثة
    if (msg.includes('؟') || msg.includes('?')) {
      if (hasTimeIndicator || hasCurrentTopic) searchScore += 0.2;
    }
    
    return searchScore >= threshold;
  }

  const forceWebBrowsing = settings.enableWebBrowsing && shouldSearch(lastUserMsg);
  
  // استخراج موضوع البحث بطريقة ذكية
  function extractSearchQuery(text) {
    // إزالة كلمات الاستفهام والأوامر
    let cleanText = text
      .replace(/^(ابحث\s+عن\s+|ابحث\s+|بحث\s+عن\s+|قم\s+بالبحث\s+عن\s+|search\s+for\s+|find\s+)/i, '')
      .replace(/^(ما\s+هي\s+|ما\s+هو\s+|what\s+is\s+|what\s+are\s+)/i, '')
      .replace(/\?$/i, '')
      .trim();
    
    return cleanText || text.trim();
  }
  
  const searchQuery = forceWebBrowsing ? extractSearchQuery(lastUserMsg) : '';

  // لا نحتاج للتحقق من وجود searchQuery لأننا نستخدم النص كاملاً

  const payload = {
    chatHistory,
    attachments: attachments.map(file => ({
      name: file.name, type: file.type, size: file.size,
      content: file.content, dataType: file.dataType, mimeType: file.mimeType
    })),
    settings,
    meta: { forceWebBrowsing, searchQuery }
  };

  try {
    await sendRequestToServer(payload);
  } catch (error) {
    console.error('Error sending request to server:', error);
    appendToStreamingMessage(`\n\n❌ حدث خطأ أثناء الاتصال بالخادم: ${error.message}`, true);
  }
}

async function sendRequestToServer(payload) {
  try {
    const token = localStorage.getItem('authToken');

    // 1) إنشاء المتحكّم وربطه بحالة البث
    const controller = new AbortController();
    streamingState.streamController = controller;

    // 2) الطلب مع signal للإلغاء الفوري
    const response = await fetch(`${API_BASE_URL}/api/chat`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { 'Authorization': `Bearer ${token}` } : {})
      },
      body: JSON.stringify(payload),
      signal: controller.signal
    });

    if (!response.ok) {
      const errorText = await response.text();
      console.error('Server Error:', response.status, errorText);
      throw new Error(`خطأ من الخادم: ${response.status} - ${errorText}`);
    }

    const reader = response.body.getReader();
    const decoder = new TextDecoder('utf-8');

    try {
      while (true) {
        const { done, value } = await reader.read(); // سيُرمى AbortError عند الإلغاء
        if (done) break;
        const chunk = decoder.decode(value, { stream: true });
        appendToStreamingMessage(chunk);
      }

      // اكتمال طبيعي
      appendToStreamingMessage('', true);

    } catch (error) {
      if (error.name === 'AbortError') {
        // تم الإلغاء: لا نرمي خطأ، أوقفنا البث بالفعل في cancelStreaming()
        console.debug('Streaming aborted by user.');
        return;
      }
      throw error;

    } finally {
      // تنظيف المقبض - لا تغيّر isStreaming هنا (تُدار في append/cancel)
      streamingState.streamController = null;
    }

  } catch (error) {
    // أخطاء شبكة/خادم
    console.error('Fetch error:', error);
    if (error.name !== 'AbortError') {
      appendToStreamingMessage(`\n\n❌ حدث خطأ أثناء الاتصال بالخادم: ${error.message}`, true);
    }
    throw error;
  }
}

// Rest of the existing functions (chat management, UI functions, etc.)
function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function scrollToBottom() {
    const messagesArea = document.getElementById('messagesArea');
    // التمرير الفوري للأسفل
    messagesArea.scrollTop = messagesArea.scrollHeight;

    // التمرير السلس للأسفل كنسخة احتياطية
    setTimeout(() => {
        messagesArea.scrollTo({
            top: messagesArea.scrollHeight,
            behavior: 'smooth'
        });
    }, 50);
}

function updateSendButton() {
  const input = document.getElementById('messageInput');
  const sendButton = document.getElementById('sendButton');
  const fileInput = document.getElementById('fileInput');

  const hasText = input.value.trim().length > 0;
  const hasFiles = fileInput.files.length > 0;

  // إزالة أي ألوان سابقة
  sendButton.classList.remove(
    'bg-red-600', 'hover:bg-red-700',
    'bg-zeus-accent', 'hover:bg-zeus-accent-hover',
    'bg-gray-600', 'cursor-not-allowed', 'opacity-60'
  );

  if (streamingState.isStreaming) {
    sendButton.disabled = false;
    sendButton.onclick = () => cancelStreaming('button');
    sendButton.innerHTML = '<i class="fas fa-stop"></i>';
    sendButton.classList.add('bg-red-600', 'hover:bg-red-700');
  } else {
    const enabled = hasText || hasFiles;
    sendButton.disabled = !enabled;
    sendButton.onclick = () => sendMessage();
    sendButton.innerHTML = '<i class="fas fa-paper-plane"></i>';

    if (enabled) {
      sendButton.classList.add('bg-zeus-accent', 'hover:bg-zeus-accent-hover');
    } else {
      sendButton.classList.add('bg-gray-600', 'cursor-not-allowed', 'opacity-60');
    }
  }
}

// ==== إلغاء البث الحالي ====
function cancelStreaming(reason = 'user') {
  if (!streamingState.isStreaming) return;

  try {
    if (streamingState.streamController) {
      streamingState.streamController.abort(); // يقطع fetch فوراً
    }
  } catch (_) {}

  // إنهاء بصري أنيق مع حفظ ما وصلنا إليه
  appendToStreamingMessage('\n\n⏹️ تم إيقاف التوليد.', true);

  // تحديث الحالة والزر
  streamingState.isStreaming = false;
  streamingState.streamController = null;
  updateSendButton();

  // إشعار اختياري
  showNotification('تم إيقاف التوليد', 'info');
}

// إلغاء عند إغلاق/تحديث الصفحة
window.addEventListener('beforeunload', () => {
  if (streamingState.isStreaming && streamingState.streamController) {
    streamingState.streamController.abort();
  }
});

// اختصار لوحة المفاتيح: Escape يوقف البث
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && streamingState.isStreaming) {
    cancelStreaming('escape');
  }
});

// Chat management functions

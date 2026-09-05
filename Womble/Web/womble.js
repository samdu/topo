// The Womble a television can open. One document from the hub, polled;
// everything else is what to do with it.
//
// No framework and no build step on purpose: this is served off a Mac on
// the house's own network to whatever browser an old TV happens to have, so
// it is ES5-shaped, uses XMLHttpRequest rather than fetch, and touches
// nothing newer than the DOM those screens already had.
//
// The document it reads is `docs/surfaces.md`.
(function () {
  'use strict';

  // How often to ask. A wall screen wants to be current more than it wants
  // to be quick; the hub answers 304 when nothing has changed.
  var INTERVAL = 5000;
  var source = new URLSearchParams(window.location.search).get('from') || 'surface.json';

  var screenEl = document.getElementById('screen');
  var cardsEl = document.getElementById('cards');
  var turnsEl = document.getElementById('turns');
  var boardEmpty = document.getElementById('board-empty');
  var transcriptEmpty = document.getElementById('transcript-empty');
  var noticeEl = document.getElementById('notice');
  var statusEl = document.getElementById('status');

  var lastEtag = null;
  var shown = null;

  function text(el, value) {
    while (el.firstChild) { el.removeChild(el.firstChild); }
    if (value) { el.appendChild(document.createTextNode(value)); }
  }

  function when(iso) {
    var date = new Date(iso);
    if (isNaN(date.getTime())) { return ''; }
    var now = new Date();
    var sameDay = date.toDateString() === now.toDateString();
    var time = date.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
    return sameDay ? time : date.toLocaleDateString([], { month: 'short', day: 'numeric' }) + ' ' + time;
  }

  function renderBoard(board) {
    var cards = (board && board.cards) || [];
    // What is still asking for something. A ticked card is not deleted, but
    // a noticeboard is for what is open.
    var open = cards.filter(function (card) { return card.state === 'posted'; });
    while (cardsEl.firstChild) { cardsEl.removeChild(cardsEl.firstChild); }
    open.forEach(function (card) {
      var li = document.createElement('li');
      var body = document.createElement('span');
      body.className = 'body';
      text(body, card.body);
      var who = document.createElement('span');
      who.className = 'who';
      text(who, card.owner + (card.postedAt ? ' · ' + when(card.postedAt) : ''));
      li.appendChild(body);
      li.appendChild(who);
      cardsEl.appendChild(li);
    });
    boardEmpty.hidden = open.length > 0;
  }

  function renderTranscript(transcript) {
    var turns = (transcript && transcript.turns) || [];
    while (turnsEl.firstChild) { turnsEl.removeChild(turnsEl.firstChild); }
    turns.forEach(function (turn) {
      var li = document.createElement('li');
      li.className = turn.role === 'assistant' ? 'assistant' : 'person';
      var who = document.createElement('span');
      who.className = 'who';
      text(who, (turn.role === 'assistant' ? 'Topo' : 'You') + (turn.at ? ' · ' + when(turn.at) : ''));
      var body = document.createElement('span');
      body.className = 'text';
      text(body, turn.text);
      li.appendChild(who);
      li.appendChild(body);
      turnsEl.appendChild(li);
    });
    transcriptEmpty.hidden = turns.length > 0;

    // Anything the read could not account for is said rather than hidden,
    // the way the app says it.
    var notice = transcript && transcript.notice;
    text(noticeEl, notice || '');
    noticeEl.hidden = !notice;

    // The newest turn is the one worth seeing.
    var atEnd = turnsEl.parentNode.scrollTop + turnsEl.parentNode.clientHeight
      >= turnsEl.parentNode.scrollHeight - 40;
    if (atEnd || shown === null) {
      turnsEl.parentNode.scrollTop = turnsEl.parentNode.scrollHeight;
    }
  }

  function render(surface) {
    renderBoard(surface.board);
    renderTranscript(surface.transcript);
    screenEl.setAttribute('data-state', 'ready');
    shown = surface;
    text(statusEl, '');
  }

  function failed(why) {
    // A screen that has something on it keeps it: what the house last
    // posted is still what it posted. A screen that has nothing says why.
    if (shown) {
      text(statusEl, 'Not reaching the hub. Showing what it last said.');
    } else {
      screenEl.setAttribute('data-state', 'failed');
      text(statusEl, why);
    }
  }

  function poll() {
    var request = new XMLHttpRequest();
    request.open('GET', source + (source.indexOf('?') === -1 ? '?' : '&') + 't=' + Date.now(), true);
    if (lastEtag) { request.setRequestHeader('If-None-Match', lastEtag); }
    request.onreadystatechange = function () {
      if (request.readyState !== 4) { return; }
      if (request.status === 304) { text(statusEl, ''); return; }
      if (request.status < 200 || request.status >= 300) {
        failed('The hub answered ' + request.status + '.');
        return;
      }
      var surface;
      try {
        surface = JSON.parse(request.responseText);
      } catch (error) {
        failed('The hub sent something this screen could not read.');
        return;
      }
      if (surface.version !== 1) {
        failed('This screen is older than the hub: it speaks version 1.');
        return;
      }
      lastEtag = request.getResponseHeader('ETag');
      render(surface);
    };
    request.onerror = function () { failed('No answer from the hub.'); };
    try {
      request.send();
    } catch (error) {
      failed('No answer from the hub.');
    }
  }

  poll();
  window.setInterval(poll, INTERVAL);

  // For a browser that is opened, left, and come back to a day later.
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) { poll(); }
  });
})();

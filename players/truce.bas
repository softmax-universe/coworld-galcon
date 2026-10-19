' Local 16-player preview: distance rows initialize across ticks; pair IDs use stride 17.
' Veles v5 - v2 without the 25% margin on enemy-owned targets
' base.bas: v5 plus an open-chat truce protocol. In the opening (ticks 64-960) a bot
' that sees an enemy's planet next to its own asks "<Color> truce?" once per player in
' global chat; every bot keeps a table of who is in a truce with whom from that chat, so a
' bot that already has a partner is not asked again; a bot with no truce answers
' "yes <Color>" (else "no <Color>"); partners never attack each other; a partner that
' takes one of your planets is a breaker, announced as "<Color> broke truce", and every
' bot that hears it attacks the breaker; a truce ends when only the two partners are left.
' Each ready planet keeps a garrison that covers the largest attack an enemy
' neighbour can throw (three quarters of its stock, the Classic rule), then
' pays for the cheapest productive target it can take outright, counting
' the defender growth during the flight; surplus with no affordable target
' walks to the own planet nearest the enemy.
dim dist(16383)
dim pending(127)
dim pressure(127)
dim contested(127)
dim avoidUntil(127)
dim truce(16)
dim breaker(16)
dim asked(16)
dim lastOwner(127)
dim ownedSince(127)
dim truceTick(16)
dim ended(16)
dim pair(288)

if prepared = 0 then
  count = planetCount()
  a = initRow
  while a < count and a < initRow + 1
    b = 0
    while b < count
      dx = x(a) - x(b)
      dy = y(a) - y(b)
      d = dx * dx + dy * dy
      lo = 0
      hi = 1024
      while lo < hi
        mid = (lo + hi) \ 2
        if mid * mid < d then
          lo = mid + 1
        else
          hi = mid
        end if
      wend
      r = lo
      dist(a * 128 + b) = r
      b = b + 1
    wend
    a = a + 1
  wend
  initRow = a
  if initRow < count then
    end
  end if
  prepared = 1
end if

self = selfPlayer()
tick = worldTick()
count = planetCount()

' Read actual fleets so delayed arrivals never look like missing launches.
q = 0
while q < count
  pending(q) = incoming(q, self)
  pressure(q) = 0
  attackers = 0
  o = 1
  while o <= playerCount()
    if o <> self and o <> owner(q) and incoming(q, o) > 0 then
      pressure(q) = pressure(q) + incoming(q, o)
      attackers = attackers + 1
    end if
    o = o + 1
  wend
  defenders = ships(q) + incoming(q, owner(q))
  contested(q) = 0
  if pressure(q) >= defenders + 2 or attackers >= 2 and pressure(q) >= 10 then
    contested(q) = 1
  end if
  q = q + 1
wend

players = playerCount()
me$ = lcase$(playerColor$(self))

' Count live players and partners, and notice partners taking our planets.
alive = 0
partners = 0
o = 1
while o <= players
  present = 0
  p = 0
  while p < count
    if owner(p) = o then
      present = 1
    end if
    p = p + 1
  wend
  if present = 1 then
    alive = alive + 1
  end if
  if truce(o) = 1 then
    partners = partners + 1
  end if
  o = o + 1
wend
if prepared = 1 and tick > 0 then
  p = 0
  while p < count
    if lastOwner(p) = self and owner(p) <> self and truce(owner(p)) = 1 then
      ' A partner took one of our planets. Ships launched before the truce or
      ' before we held the planet are forgiven: the longest flight from any of
      ' the partner's planets bounds how late such ships can still land.
      b = owner(p)
      reach = 0
      q = 0
      while q < count
        if owner(q) = b and dist(p * 128 + q) > reach then
          reach = dist(p * 128 + q)
        end if
        q = q + 1
      wend
      reach = reach + 32
    end if
    if lastOwner(p) = self and owner(p) <> self and truce(owner(p)) = 1 and tick - ownedSince(p) > reach and tick - truceTick(owner(p)) > reach then
      b = owner(p)
      truce(b) = 0
      breaker(b) = 1
      partners = partners - 1
      sent = sendChat(-2, lcase$(playerColor$(b)) + " broke truce")
    end if
    p = p + 1
  wend
end if
p = 0
while p < count
  if lastOwner(p) <> owner(p) then
    if lastOwner(p) > 0 and tick - ownedSince(p) <= 256 then
      avoidUntil(p) = tick + 256
    end if
    ownedSince(p) = tick
  end if
  lastOwner(p) = owner(p)
  p = p + 1
wend

' A truce ends when only the two partners remain.
if alive = 2 and partners = 1 then
  o = 1
  while o <= players
    if truce(o) = 1 then
      truce(o) = 0
      ended(o) = 1
      sent = sendChat(-2, "truce over " + lcase$(playerColor$(o)))
    end if
    o = o + 1
  wend
  partners = 0
end if

' Read the open chat: proposals, answers and breaker reports.
said = 0
message$ = pullMailbox$()
if message$ <> "" then
  text$ = lcase$(message$)
  from = 0
  o = 1
  while o <= players
    name$ = lcase$(playerColor$(o))
    if left$(text$, len(name$) + 1) = name$ + ":" then
      from = o
    end if
    o = o + 1
  wend
  if from > 0 then
    from$ = lcase$(playerColor$(from))
    body$ = ltrim$(mid$(text$, len(from$) + 2))
    ' Keep the table of who is in a truce with whom, for every pair.
    o = 1
    while o <= players
      name$ = lcase$(playerColor$(o))
      if body$ = "yes " + name$ or body$ = name$ + " yes" then
        pair(from * 17 + o) = 1
        pair(o * 17 + from) = 1
      elseif body$ = name$ + " broke truce" or body$ = "truce over " + name$ then
        pair(from * 17 + o) = 0
        pair(o * 17 + from) = 0
      end if
      o = o + 1
    wend
  end if
  if from > 0 and from <> self then
    if body$ = me$ + " truce?" or body$ = "truce " + me$ + "?" then
      if said = 0 then
        flying = 0
        q = 0
        while q < count
          if owner(q) = from and pending(q) > 0 then
            flying = 1
          end if
          q = q + 1
        wend
        if partners = 0 and breaker(from) = 0 and ended(from) = 0 and flying = 0 then
          truce(from) = 1
          truceTick(from) = tick
          partners = 1
          sent = sendChat(-2, "yes " + from$)
        else
          sent = sendChat(-2, "no " + from$)
        end if
        said = 1
      end if
    elseif body$ = "yes " + me$ or body$ = me$ + " yes" then
      if asked(from) = 1 and breaker(from) = 0 then
        truce(from) = 1
        truceTick(from) = tick
        partners = partners + 1
      end if
    elseif right$(body$, 12) = " broke truce" then
      ' Everyone marks the reported breaker.
      o = 1
      while o <= players
        if body$ = lcase$(playerColor$(o)) + " broke truce" and o <> self then
          breaker(o) = 1
          if truce(o) = 1 then
            truce(o) = 0
            partners = partners - 1
          end if
        end if
        o = o + 1
      wend
    end if
  end if
end if

' Propose a truce to a neighbour when we have none: only in the opening
' (ticks 64-960), once per player per game, never to a player who already has
' a partner, and never while our ships fly at them.
if partners = 0 and said = 0 and tick >= 64 and tick <= 960 then
  p = 0
  while p < count and said = 0
    if owner(p) = self then
      rank = 0
      while rank < neighborCount(p) and said = 0
        e = owner(neighbor(p, rank))
        flying = 0
        if e <> self and e <> 0 then
          q = 0
          while q < count
            if owner(q) = e and pending(q) > 0 then
              flying = 1
            end if
            q = q + 1
          wend
        end if
        taken = 0
        if e <> self and e <> 0 then
          o = 1
          while o <= players
            if pair(e * 17 + o) = 1 then
              taken = 1
            end if
            o = o + 1
          wend
        end if
        if e <> self and e <> 0 and breaker(e) = 0 and ended(e) = 0 and asked(e) = 0 and flying = 0 and taken = 0 then
          asked(e) = 1
          sent = sendChat(-2, lcase$(playerColor$(e)) + " truce?")
          said = 1
        end if
        rank = rank + 1
      wend
    end if
    p = p + 1
  wend
end if

' Stage near an enemy target that is not already covered or contested.
front = -1
frontDist = 1000000
p = 0
while p < count
  if owner(p) = self then
    q = 0
    while q < count
      if owner(q) <> self and owner(q) <> 0 and truce(owner(q)) = 0 and contested(q) = 0 and tick >= avoidUntil(q) and pending(q) < ships(q) + incoming(q, owner(q)) + 2 then
        if dist(p * 128 + q) < frontDist then
          frontDist = dist(p * 128 + q)
          front = p
        end if
      end if
      q = q + 1
    wend
  end if
  p = p + 1
wend

p = 0
while p < count
  if owner(p) = self and ready(p) <> 0 then
    reserve = 3
    rank = 0
    while rank < neighborCount(p)
      e = neighbor(p, rank)
      if owner(e) <> self and owner(e) <> 0 and truce(owner(e)) = 0 then
        guard = (ships(e) * 3) \ 4 + 3
        if guard > reserve then
          reserve = guard
        end if
      end if
      rank = rank + 1
    wend
    threat = reserve - 3
    avail = ships(p) - reserve
    launches = 0
    while avail >= 5 and launches < 3
      best = -1
      bestScore = 0
      bestNeed = 0
      q = 0
      while q < count
        if owner(q) <> self and truce(owner(q)) = 0 and contested(q) = 0 and tick >= avoidUntil(q) then
          eta = dist(p * 128 + q)
          need = ships(q) + incoming(q, owner(q)) + 2 + (production(q) * morale(q) * eta) \ 160000 - pending(q)
          if need > 0 and need <= avail then
            score = (production(q) + 12) * 1000 \ ((need + pressure(q) + 4) * (eta + 48))
            if breaker(owner(q)) = 1 then
              score = score * 3
            end if
            if score > bestScore then
              bestScore = score
              best = q
              bestNeed = need
            end if
          end if
        end if
        q = q + 1
      wend
      if best >= 0 then
        sent = launch(p, best, bestNeed)
        if sent > 0 then
          avail = avail - sent
          pending(best) = pending(best) + sent
        else
          avail = 0
        end if
        launches = launches + 1
      else
        avail = 0
      end if
    wend
    ' Nothing affordable: walk the surplus to the front.
    if launches = 0 and front >= 0 and front <> p and threat <= 0 then
      spare = ships(p) - 10
      if spare >= 20 then
        sent = launch(p, front, spare \ 2)
      end if
    end if
  end if
  p = p + 1
wend

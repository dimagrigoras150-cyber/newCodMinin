script_name('AURA CORE SYSTEM v3.3 Beta')
-- Подключение библиотек и кодировкаІ
local imgui = require('mimgui')
local encoding = require('encoding')
local sampev = require("lib.samp.events")
local vkeys = require('vkeys')
encoding.default = 'CP1251'
local u8 = encoding.UTF8
-- ===== БАЗОВОЕ СОСТОЯНИЕ =====
local showMenu = imgui.new.bool(false)
local showControlCenter = imgui.new.bool(false)
local showMonitoring = imgui.new.bool(false)
local showSettings = imgui.new.bool(false)
local pendingAutoScan = false
local scanStepBusy = false
local auraEnabled = true
local waitingHouseReturn = false
local refreshOneHouse = false
local imgui_font = nil
local collectDelay = imgui.new.int(50)

local singleHouseRefresh = {
    active = false,
    house = 1
}

local btcCollector = {
    active = false,
    house = 1,
    gpu = 1
}

local gpuStarter = {
    active = false,
    house = 1
}

local globalBtcCollector = {
    active = false,
    house = 1
}

local btcStats = {
    collected = 0
}

local singleBtcStats = {
    collected = 0
}

local scanner = {
    active = false,
    house = 1,
    maxHouses = 15,
    houseDialogId = nil,
    gpuDialogId = nil,
    waitingHouseDialog = false,
    waitingGpuDialog = false,
    lastAction = 0
}

local btcRate = 0
local totalBTC = 0
local maxHouses = 15
local maxGpu = 20
local selectedHouseTab = 1
local selectedGpuCard = 1
-- Данные по видеокартам: gpu_data[дом][карта]
local gpu_data = {}

for h = 1, maxHouses do
    gpu_data[h] = {}
    for i = 1, maxGpu do
        gpu_data[h][i] = {
            status = u8"Нет данных",
            btc = "0.000000",
            level = "0",
            temp = "0"
        }
    end
end

local manualOpen = {
    active = false
}

-- ===== ДВИЖОК БОТА =====
local bot = {
    enabled = false,          -- включен ли бот
    mode = "idle",            -- idle / one_house / all_houses / scan
    state = "idle",           -- wait_house_list / wait_gpu_list / wait_gpu_menu
    house = 1,                -- текущий дом
    gpu = 1,                  -- текущая видеокарта
    needLaunchPaused = false, -- потом пригодится
    scanHouse = 1,            -- для глобального сканирования
    isScanning = false
}
-- ===== СЛУЖЕБНЫЕ ФУНКЦИИ =====
local function msg(text)
    sampAddChatMessage("{FFD700}[AURA] {FFFFFF}" .. text, -1)
end

local function formatNumberDots(n)
    local left, num, right = tostring(n):match('^([^%d]*%d)(%d*)(.-)$')
    return left .. (num:reverse():gsub('(%d%d%d)', '%1.'):reverse()) .. right
end

local function refreshSelectedHouse()
    if scanner.active or singleHouseRefresh.active then return end

    singleHouseRefresh.active = true
    singleHouseRefresh.house = selectedHouseTab

    msg("Обновление дома #" .. singleHouseRefresh.house)

    lua_thread.create(function()
        wait(200)
        sampProcessChatInput("/flashminer")
    end)
end

local function resetScannerState()
    scanner.active = false
    scanner.house = 1
    scanner.houseDialogId = nil
    scanner.gpuDialogId = nil
    scanner.waitingHouseDialog = false
    scanner.waitingGpuDialog = false
    scanner.lastAction = 0

    bot.isScanning = false
    bot.scanHouse = 1
    manualOpen.active = false
end

local function resetBotProgress()
    bot.house = selectedHouseTab
    bot.gpu = 1
    bot.state = "idle"
end

local function openAuraUiWithMonitoring()
    showMenu[0] = true
    showControlCenter[0] = false
    showMonitoring[0] = true
    imgui.ShowCursor = true
end

local function stopBot(reason)
    bot.enabled = false
    bot.mode = "idle"
    bot.state = "idle"
    if reason then
        msg(reason)
    end
end

local function startOneHouse()
    bot.enabled = true
    bot.mode = "one_house"
    bot.house = selectedHouseTab
    bot.gpu = 1
    bot.state = "wait_house_list"
    msg("Запуск сбора для дома #" .. bot.house)
    sampProcessChatInput("/flashminer")
end

local function startAllHouses()
    bot.enabled = true
    bot.mode = "all_houses"
    bot.house = 1
    bot.gpu = 1
    bot.state = "wait_house_list"
    msg("Запуск сбора со всех домов")
    sampProcessChatInput("/flashminer")
end

local scanCooldown = false

local function startGlobalScan()
    if scanner.active then return end

    scanner.active = true
    scanner.house = 1
    scanner.houseDialogId = nil
    scanner.gpuDialogId = nil
    scanner.waitingHouseDialog = true
    scanner.waitingGpuDialog = false
    scanner.lastAction = os.clock()

    bot.isScanning = true
    bot.scanHouse = 1

    openAuraUiWithMonitoring()
    msg("Запуск синхронизации всех домов")

    sampProcessChatInput("/flashminer")
end

function sendcef(str)
    local bs = raknetNewBitStream()
    raknetBitStreamWriteInt8(bs, 220)
    raknetBitStreamWriteInt8(bs, 18)
    raknetBitStreamWriteInt16(bs, #str)
    raknetBitStreamWriteString(bs, str)
    raknetBitStreamWriteInt32(bs, 0)
    raknetSendBitStream(bs)
    raknetDeleteBitStream(bs)
end

function main()
    while not isSampAvailable() do
        wait(500)
    end

    msg("Скрипт загружен. F2 - меню")
	resetScannerState()
    sampRegisterChatCommand("aura", function()
		auraEnabled = not auraEnabled

		resetScannerState()

		if auraEnabled then
			msg("Скрипт включен")
		else
			msg("Скрипт выключен")
		end
	end)

    while true do
        wait(0)

        if isKeyJustPressed(vkeys.VK_F2) then
            showMenu[0] = not showMenu[0]

            imgui.ShowCursor = showMenu[0] or showControlCenter[0] or showMonitoring[0]

            if showMenu[0] then
                lua_thread.create(function()
                    wait(300)
                    sampSendChat('/phone')
                    wait(200)
                    sendcef('launchedApp|39')
                    wait(200)
                    sampSendChat('/phone')
                end)
            end
        end

        -- ===== ОБРАБОТКА СКАНЕРА =====
        if scanner.active then
            -- если ждём окно выбора дома, но оно не пришло
            if scanner.waitingHouseDialog and os.clock() - scanner.lastAction > 5 then
                scanner.lastAction = os.clock()
                sampProcessChatInput("/flashminer")
            end
        end
    end
end

local function renderGradientText(text, speed)
    local speed = speed or 2.0
    local time = os.clock() * speed
    local x_offset = 0
    
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        -- Рассчитываем волну для блика
        local wave = math.sin(time - (x_offset * 0.1)) * 0.5 + 0.5
        
        -- Цвета: от насыщенного оранжевого до ярко-желтого
        -- Это создаст эффект «бегущего блика» по золоту
        local r = 1.0
        local g = 0.5 + (wave * 0.4) -- Плавает от 0.5 до 0.9
        local b = 0.0
        
        imgui.TextColored(imgui.ImVec4(r, g, b, 1.0), char)
        imgui.SameLine(0, 0)
        x_offset = x_offset + imgui.CalcTextSize(char).x
    end
    imgui.NewLine()
end

imgui.OnInitialize(function()
    local config = imgui.ImFontConfig()
    config.GlyphRanges = imgui.GetIO().Fonts:GetGlyphRangesCyrillic()
    
    local fontPath = getWorkingDirectory() .. '\\font\\agora.ttf' 
    local solidPath = getWorkingDirectory() .. '\\font\\fa-solid-900.ttf' 
    local brandPath = getWorkingDirectory() .. '\\font\\fa-brands-400.ttf' -- СКАЧАЙ ЭТОТ ФАЙЛ

    if doesFileExist(fontPath) then
        -- 1. Основной шрифт
        imgui_font = imgui.GetIO().Fonts:AddFontFromFileTTF(fontPath, 18, config) 
        
        -- Конфиг для подмешивания
        local iconConfig = imgui.ImFontConfig()
        iconConfig.MergeMode = true
        iconConfig.PixelSnapH = true
        -- РАСШИРЕННЫЙ ДИАПАЗОН (чтобы видело всё)
        local iconRanges = imgui.new.uint16_t[3]({0xf000, 0xffff, 0})

        -- 2. Подмешиваем Solid (иконки системные)
        if doesFileExist(solidPath) then
            imgui.GetIO().Fonts:AddFontFromFileTTF(solidPath, 20, iconConfig, iconRanges)
        end

        -- 3. Подмешиваем Brands (Биткоин, Телеграм и т.д.)
        if doesFileExist(brandPath) then
            imgui.GetIO().Fonts:AddFontFromFileTTF(brandPath, 20, iconConfig, iconRanges)
        end
        
        imgui.GetIO().Fonts:Build()
    end
end)

imgui.OnFrame(function() return showMenu[0] end, function(player)
    if imgui_font then imgui.PushFont(imgui_font) end

    local currentHouse = bot.house
    local currentStep = bot.gpu
    local active = bot.enabled
    local isScanning = bot.isScanning
    local scanHouse = scanner.active and math.min(scanner.house, maxHouses) or bot.scanHouse

    -- ===== ЕДИНЫЙ СТИЛЬ =====
    local style = imgui.GetStyle()
    style.WindowRounding, style.WindowBorderSize = 12.0, 1.5
    style.WindowPadding = imgui.ImVec2(20, 20)

    imgui.PushStyleColor(imgui.Col.WindowBg, imgui.ImVec4(0.06, 0.06, 0.06, 0.96))
    imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(1.0, 0.7, 0.0, 0.5))
    imgui.PushStyleColor(imgui.Col.TitleBg, imgui.ImVec4(0.1, 0.1, 0.1, 1.0))
    imgui.PushStyleColor(imgui.Col.TitleBgActive, imgui.ImVec4(0.15, 0.15, 0.15, 1.0))
    imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(1.0, 0.8, 0.0, 1.0))
    imgui.PushStyleColor(imgui.Col.ResizeGrip, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ResizeGripHovered, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ResizeGripActive, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0, 0, 0, 0))
    imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(1.0, 0.7, 0.0, 0.2))
    imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(1.0, 0.7, 0.0, 0.4))

    -- ===== ГЛАВНОЕ ОКНО =====
    imgui.SetNextWindowPos(imgui.ImVec2(20, 350), imgui.Cond.FirstUseEver)
    imgui.SetNextWindowSize(imgui.ImVec2(400, 0), imgui.Cond.Always)
    imgui.Begin("AURA CORE SYSTEM", showMenu, imgui.WindowFlags.NoDecoration)

        local startPos, winPos = imgui.GetCursorScreenPos(), imgui.GetWindowPos()
        local winWidth, draw = imgui.GetWindowWidth(), imgui.GetWindowDrawList()
        local color, radius = 0xCC00AAFF, 9

        -- ИКОНКА КУРСА
        local iX, iY = winPos.x + 350, winPos.y + 22
        draw:AddCircle(imgui.ImVec2(iX, iY), radius, color, 20, 1.3)
        imgui.SetCursorScreenPos(imgui.ImVec2(iX - 3, iY - 7))
        imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 0.8), "i")
        imgui.SetCursorScreenPos(imgui.ImVec2(iX - 10, iY - 10))
        imgui.InvisibleButton("##info_btn", imgui.ImVec2(20, 20))
        if imgui.IsItemHovered() then
            imgui.BeginTooltip()
                imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), u8" ТЕКУЩИЙ КУРС:")
                local drawT, pT, wT = imgui.GetWindowDrawList(), imgui.GetCursorScreenPos(), imgui.GetWindowWidth()
                drawT:AddRectFilledMultiColor(
                    imgui.ImVec2(pT.x, pT.y + 2),
                    imgui.ImVec2(pT.x + wT - 10, pT.y + 4),
                    0xFF00AAFF, 0x0000AAFF, 0x0000AAFF, 0xFF00AAFF
                )
                imgui.Dummy(imgui.ImVec2(0, 10))
                imgui.Text(u8"Bitcoin: ")
                imgui.SameLine()
                imgui.TextColored(imgui.ImVec4(0.0, 1.0, 0.5, 1.0), "$" .. tostring(btcRate))
            imgui.EndTooltip()
        end

        -- ИКОНКА CONTROL CENTER
        local bX, bY = winPos.x + 380, winPos.y + 22
        draw:AddCircle(imgui.ImVec2(bX, bY), radius, color, 20, 1.3)
        draw:AddLine(imgui.ImVec2(bX - 5, bY - 4), imgui.ImVec2(bX + 5, bY - 4), color, 1.5)
        draw:AddLine(imgui.ImVec2(bX - 5, bY), imgui.ImVec2(bX + 5, bY), color, 1.5)
        draw:AddLine(imgui.ImVec2(bX - 5, bY + 4), imgui.ImVec2(bX + 5, bY + 4), color, 1.5)
        imgui.SetCursorScreenPos(imgui.ImVec2(bX - 10, bY - 10))
        if imgui.InvisibleButton("##b_btn", imgui.ImVec2(20, 20)) then
            showControlCenter[0] = not showControlCenter[0]
            imgui.ShowCursor = showMenu[0] or showControlCenter[0] or showMonitoring[0]
        end
        if imgui.IsItemHovered() then
            imgui.BeginTooltip()
            imgui.Text(u8"Центр Управления")
            imgui.EndTooltip()
        end

        -- КОНТЕНТ
        imgui.SetCursorScreenPos(startPos)

        local icon_bolt = " \239\131\167"
        renderGradientText(icon_bolt .. u8"  AURA CORE SYSTEM", 2.0)

        imgui.SameLine()
        imgui.TextDisabled(" v3.3 Rebuild")

        local p = imgui.GetCursorScreenPos()
        draw:AddRectFilledMultiColor(
            imgui.ImVec2(p.x, p.y + 5),
            imgui.ImVec2(p.x + winWidth - 40, p.y + 7),
            0xFF00AAFF, 0x0000AAFF, 0x0000AAFF, 0xFF00AAFF
        )
        imgui.Dummy(imgui.ImVec2(0, 15))

        imgui.Text(u8"Статус: ")
        imgui.SameLine()
        if active then
            imgui.TextColored(imgui.ImVec4(0.0, 1.0, 0.0, 1.0), "ACTIVE")
        else
            imgui.TextColored(imgui.ImVec4(1.0, 0.2, 0.2, 1.0), "STANDBY")
        end

        imgui.Spacing()
        imgui.Text(u8(string.format("Дом: %d/%d | Карта: %d/%d", currentHouse, maxHouses, currentStep, maxGpu)))
        imgui.Text(u8"Собрано за сессию: ")
        imgui.SameLine()
        imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), tostring(totalBTC) .. " BTC")

        if btcRate > 0 then
            imgui.Text(u8"Примерная прибыль: ")
            imgui.SameLine()
            imgui.TextColored(imgui.ImVec4(0.0, 1.0, 0.5, 1.0), "$" .. math.floor(totalBTC * btcRate))
        end

        imgui.Dummy(imgui.ImVec2(0, 10))
        imgui.Separator()
        imgui.Spacing()

        if active then
            local statusText = u8("Обработка дома #" .. tostring(currentHouse) .. ", видеокарта #" .. tostring(currentStep))
            imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), statusText)
            local pB, wB, prg = imgui.GetCursorScreenPos(), winWidth - 40, (os.clock() % 2) / 2
            draw:AddRectFilled(imgui.ImVec2(pB.x, pB.y + 2), imgui.ImVec2(pB.x + wB, pB.y + 4), 0x22FFFFFF)
            draw:AddRectFilled(imgui.ImVec2(pB.x + (wB * prg), pB.y + 2), imgui.ImVec2(pB.x + (wB * prg) + 20, pB.y + 4), 0xFF00AAFF)
            imgui.Dummy(imgui.ImVec2(0, 10))
        else
            imgui.PushStyleColor(imgui.Col.Text, imgui.ImVec4(0.4, 0.4, 0.4, 1.0))
            imgui.Text(u8"Система в режиме ожидания")
            imgui.PopStyleColor()
        end

    imgui.End()

    -- ===== CONTROL CENTER =====
    if showControlCenter[0] then
        imgui.SetNextWindowSize(imgui.ImVec2(400, 300), imgui.Cond.FirstUseEver)
        imgui.Begin(u8"   Mining Control Center", showControlCenter, imgui.WindowFlags.NoCollapse)

            imgui.TextColored(imgui.ImVec4(1, 0.8, 0, 1), u8" ГЛАВНОЕ УПРАВЛЕНИЕ")
            imgui.Separator()
            imgui.Spacing()

            if imgui.Button(u8"   " .. "\xef\x82\x80" .. u8"   MONITORING SYSTEM", imgui.ImVec2(-1, 45)) then
                showMonitoring[0] = not showMonitoring[0]
                imgui.ShowCursor = showMenu[0] or showControlCenter[0] or showMonitoring[0]
            end
			if imgui.Button(u8"? SYSTEM SETTINGS", imgui.ImVec2(-1, 40)) then
				showSettings[0] = true
				showMonitoring[0] = false
			end

            imgui.Spacing()
            imgui.TextDisabled(u8"Другие модули пока в разработке...")

        imgui.End()
    end

    -- ===== МОНИТОРИНГ =====
    if showMonitoring[0] then
		imgui.SetNextWindowSize(imgui.ImVec2(1100, 650), imgui.Cond.Always)
		imgui.Begin(
			u8"AURA | Global Monitoring System",
			showMonitoring,
			imgui.WindowFlags.NoCollapse + imgui.WindowFlags.NoResize
		)

		local currentScanHouse = scanner and scanner.active and math.min(scanner.house, maxHouses) or bot.scanHouse

		if isScanning then
			local winSize = imgui.GetWindowSize()
			imgui.SetCursorPos(imgui.ImVec2(winSize.x / 2 - 170, winSize.y / 2 - 45))
			imgui.BeginGroup()
				renderGradientText(u8"   СИНХРОНИЗАЦИЯ ДОМА #" .. currentScanHouse, 3.0)
				imgui.Spacing()
				imgui.ProgressBar(math.min(currentScanHouse, maxHouses) / maxHouses, imgui.ImVec2(340, 16), "")
			imgui.EndGroup()
		else
			local houseData = gpu_data[selectedHouseTab] or {}

			local activeCount = 0
			local totalBtc = 0
			local avgTemp = 0
			local tempCount = 0

			for i = 1, maxGpu do
				local card = houseData[i]
				if card then
					if card.status == u8"Работает" then
						activeCount = activeCount + 1
					end

					totalBtc = totalBtc + tonumber(card.btc or "0") or 0

					local t = tonumber(card.temp or "0")
					if t then
						avgTemp = avgTemp + t
						tempCount = tempCount + 1
					end
				end
			end

			if tempCount > 0 then
				avgTemp = avgTemp / tempCount
			end

			-- КНОПКА ОБНОВИТЬ
			imgui.SetCursorPos(imgui.ImVec2(imgui.GetWindowWidth() - 50, 12))
			if imgui.Button("\xef\x80\xa1", imgui.ImVec2(30, 30)) then
				startGlobalScan()
			end
			if imgui.IsItemHovered() then
				imgui.SetTooltip(u8"Обновить данные всех домов")
			end

			-- ЛЕВАЯ ПАНЕЛЬ ДОМОВ
			imgui.BeginChild("##houses_panel", imgui.ImVec2(150, 0), true)
				imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), u8" ДОМА")
				imgui.Separator()
				imgui.Spacing()

				for i = 1, maxHouses do
					local isSelected = selectedHouseTab == i
					if isSelected then
						imgui.PushStyleColor(imgui.Col.Header, imgui.ImVec4(1.0, 0.7, 0.0, 0.25))
						imgui.PushStyleColor(imgui.Col.HeaderHovered, imgui.ImVec4(1.0, 0.7, 0.0, 0.35))
						imgui.PushStyleColor(imgui.Col.HeaderActive, imgui.ImVec4(1.0, 0.7, 0.0, 0.45))
					end

					if imgui.Selectable(u8(" Дом #" .. i), isSelected) then
						selectedHouseTab = i
						selectedGpuCard = 1
					end

					if isSelected then
						imgui.PopStyleColor(3)
					end
				end
			imgui.EndChild()

			imgui.SameLine()

			-- ПРАВАЯ ЧАСТЬ
			imgui.BeginGroup()

				-- ВЕРХНЯЯ СВОДКА
				imgui.BeginChild("##summary_panel", imgui.ImVec2(0, 110), true, imgui.WindowFlags.NoScrollbar)
					imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), u8(" ДОМ #" .. selectedHouseTab))
					imgui.Separator()

					imgui.Columns(3, nil, false)

					imgui.Text(u8"Активно карт")
					imgui.TextColored(imgui.ImVec4(0.0, 1.0, 0.5, 1.0), tostring(activeCount) .. "/" .. tostring(maxGpu))
					imgui.NextColumn()

					imgui.Text(u8"BTC всего")
					imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), string.format("%.6f", totalBtc))
					imgui.NextColumn()

					imgui.Text(u8"Средняя жидкость")
					imgui.TextColored(imgui.ImVec4(0.7, 0.9, 1.0, 1.0), string.format("%.1f %%", avgTemp))
					imgui.NextColumn()

					imgui.Columns(1)
				imgui.EndChild()

				imgui.Spacing()

				-- ЦЕНТР: СПИСОК КАРТ + ДЕТАЛИ
				imgui.BeginChild("##main_monitor_panel", imgui.ImVec2(0, -70), false)

					-- СПИСОК ВИДЕОКАРТ СЛЕВА ВНУТРИ ПРАВОЙ ОБЛАСТИ
					imgui.BeginChild("##gpu_list_panel", imgui.ImVec2(250, 0), true)
						imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), u8" ВИДЕОКАРТЫ")
						imgui.Separator()
						imgui.Spacing()

						for i = 1, maxGpu do
							local card = houseData[i]
							local label = u8(" Видеокарта #" .. i)

							if card and card.status == u8"Работает" then
								label = label .. u8("  [ON]")
							else
								label = label .. u8("  [OFF]")
							end

							if imgui.Selectable(label, selectedGpuCard == i) then
								selectedGpuCard = i
							end
						end
					imgui.EndChild()

					imgui.SameLine()

					-- ДЕТАЛЬНАЯ ПАНЕЛЬ
					imgui.BeginChild("##gpu_detail_panel", imgui.ImVec2(0, 0), true)

						local card = houseData[selectedGpuCard] or {
							status = u8"Нет данных",
							btc = "0.000000",
							level = "0",
							temp = "0"
						}

						local isWorking = (card.status == u8"Работает")

						imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), u8(" Видеокарта #" .. selectedGpuCard))
						imgui.Separator()
						imgui.Spacing()

						-- БОЛЬШАЯ КАРТОЧКА
						local p = imgui.GetCursorScreenPos()
						local draw = imgui.GetWindowDrawList()
						local panelW = imgui.GetContentRegionAvail().x
						local panelH = 170

						draw:AddRectFilled(p, imgui.ImVec2(p.x + panelW, p.y + panelH), 0x12FFFFFF, 10)
						draw:AddRect(
							p,
							imgui.ImVec2(p.x + panelW, p.y + panelH),
							isWorking and 0xAA00FF88 or 0xAA4444FF,
							10,
							15,
							1.5
						)

						imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 20, p.y + 18))
						imgui.Text(u8"Статус:")
						imgui.SameLine()
						imgui.TextColored(
							isWorking and imgui.ImVec4(0.0, 1.0, 0.5, 1.0) or imgui.ImVec4(1.0, 0.3, 0.2, 1.0),
							tostring(card.status)
						)

						imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 20, p.y + 52))
						imgui.Text(u8"BTC:")
						imgui.SameLine()
						imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), tostring(card.btc))

						imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 20, p.y + 86))
						imgui.Text(u8"Уровень:")
						imgui.SameLine()
						imgui.TextColored(imgui.ImVec4(0.8, 0.9, 1.0, 1.0), tostring(card.level))

						imgui.SetCursorScreenPos(imgui.ImVec2(p.x + 20, p.y + 120))
						imgui.Text(u8"Жидкость:")
						imgui.SameLine()
						imgui.TextColored(imgui.ImVec4(0.6, 0.9, 1.0, 1.0), tostring(card.temp) .. " %")

						imgui.Dummy(imgui.ImVec2(panelW, panelH + 10))

						-- МИНИ-СЕТКА КАРТ
						imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), u8" БЫСТРЫЙ ОБЗОР")
						imgui.Separator()
						imgui.Spacing()

						local cols = 4
						local boxW = 115
						local boxH = 52

						for i = 1, maxGpu do
							local c = houseData[i] or {}
							local on = (c.status == u8"Работает")
							local pp = imgui.GetCursorScreenPos()
							local dd = imgui.GetWindowDrawList()

							dd:AddRectFilled(pp, imgui.ImVec2(pp.x + boxW, pp.y + boxH), 0x10FFFFFF, 8)
							dd:AddRect(
								pp,
								imgui.ImVec2(pp.x + boxW, pp.y + boxH),
								on and 0xAA00FF88 or 0xAA4444FF,
								8,
								15,
								selectedGpuCard == i and 2.0 or 1.0
							)

							imgui.SetCursorScreenPos(imgui.ImVec2(pp.x + 8, pp.y + 7))
							imgui.TextColored(
								on and imgui.ImVec4(0.0, 1.0, 0.5, 1.0) or imgui.ImVec4(1.0, 0.3, 0.2, 1.0),
								on and "ON" or "OFF"
							)

							imgui.SameLine()
							imgui.Text("#" .. i)

							imgui.SetCursorScreenPos(imgui.ImVec2(pp.x + 8, pp.y + 28))
							imgui.TextColored(imgui.ImVec4(1.0, 0.8, 0.0, 1.0), tostring(c.btc or "0.000000"))

							imgui.SetCursorScreenPos(pp)
							if imgui.InvisibleButton("gpu_box_" .. i, imgui.ImVec2(boxW, boxH)) then
								selectedGpuCard = i
							end

							if i % cols ~= 0 then
								imgui.SameLine(0, 10)
							else
								imgui.Spacing()
							end
						end

					imgui.EndChild()

				imgui.EndChild()

				-- НИЖНИЕ КНОПКИ
				imgui.BeginChild("##bottom_buttons", imgui.ImVec2(0, 64), false)

					local availW = imgui.GetContentRegionAvail().x
					local spacing = 10
					local btnW = (availW - spacing * 3) / 4
					local btnH = 40

					imgui.PushStyleColor(imgui.Col.Button, imgui.ImVec4(0.10, 0.10, 0.10, 0.95))
					imgui.PushStyleColor(imgui.Col.ButtonHovered, imgui.ImVec4(0.18, 0.14, 0.05, 0.95))
					imgui.PushStyleColor(imgui.Col.ButtonActive, imgui.ImVec4(0.25, 0.18, 0.06, 0.95))
					imgui.PushStyleColor(imgui.Col.Border, imgui.ImVec4(1.0, 0.75, 0.0, 0.65))

					if imgui.Button(u8"СОБРАТЬ BTC", imgui.ImVec2(btnW, btnH)) then
						singleBtcStats.collected = 0

						btcCollector.active = true
						btcCollector.house = selectedHouseTab
						btcCollector.gpu = 1

						sampProcessChatInput("/flashminer")
					end
					imgui.SameLine(0, spacing)

					if imgui.Button(u8"ЗАПУСТИТЬ КАРТЫ", imgui.ImVec2(btnW, btnH)) then
						gpuStarter.active = true
						gpuStarter.house = selectedHouseTab
						sampProcessChatInput("/flashminer")
					end
					imgui.SameLine(0, spacing)

					if imgui.Button(u8"ОБНОВИТЬ ДОМ", imgui.ImVec2(btnW, btnH)) then
						singleHouseRefresh.active = true
						singleHouseRefresh.house = selectedHouseTab
						sampProcessChatInput("/flashminer")
					end
					imgui.SameLine(0, spacing)

					if imgui.Button(u8"ОБНОВИТЬ ВСЕ ДОМА", imgui.ImVec2(btnW, btnH)) then
						startGlobalScan()
					end
					
					if imgui.Button(u8"СОБРАТЬ BTC СО ВСЕХ", imgui.ImVec2(btnW, btnH)) then
						btcStats.collected = 0

						globalBtcCollector.active = true
						globalBtcCollector.house = 1

						btcCollector.active = true
						btcCollector.house = 1
						btcCollector.gpu = 1

						sampProcessChatInput("/flashminer")
					end

					imgui.PopStyleColor(4)

				imgui.EndChild()

			imgui.EndGroup()
		end

		imgui.End()

	end
	
	if showSettings[0] then
		imgui.Begin(u8"AURA | System Settings", showSettings)

		imgui.Text(u8"Скорость операций")

		imgui.SliderInt(u8"Скорость сбора BTC", collectDelay, 80, 400)

		imgui.Separator()

		imgui.Text(u8"Будущие настройки:")

		imgui.BulletText(u8"Авто сбор BTC")
		imgui.BulletText(u8"Авто запуск карт")
		imgui.BulletText(u8"Авто охлаждение")

		imgui.End()
	end

    imgui.PopStyleColor(11)
    if imgui_font then imgui.PopFont() end
end)

function sampev.onServerMessage(color, text)
    local cleanText = text:gsub('{......}', '')

    local amount = cleanText:match("Вы вывели%s+(%d+)%s+BTC")
    if amount then
        amount = tonumber(amount) or 0

        if amount > 0 and btcCollector.active then
            singleBtcStats.collected = singleBtcStats.collected + amount
        end
    end
end

function sampev.onShowDialog(id, style, title, button1, button2, text)
    local cleanTitle = title:gsub('{......}', '')

    if not auraEnabled then
        return
    end

    -- ===== ТИХИЙ ПЕРЕХВАТ КУРСА =====
    if cleanTitle:find("Курс валют") then
        local rateVal = text:match("Bitcoin %(BTC%):%s+%$([%d]+)")
        if rateVal then
            btcRate = tonumber(rateVal)

            lua_thread.create(function()
                wait(200)
                sampSendDialogResponse(id, 0, 0, "")
            end)

            return false
        end
    end

    -- ===== ВЫБОР ДОМА =====
	if cleanTitle == "Выбор дома"
	and text:find("Номер дома")
	and text:find("Город")
	and text:find("Налог")
	and text:find("Энергия") then
		if scanner.active then
			scanner.houseDialogId = id
			scanner.waitingHouseDialog = false

			if scanner.house <= scanner.maxHouses then
				lua_thread.create(function()
					wait(400)
					sampSendDialogResponse(id, 1, scanner.house - 1, "")
					scanner.waitingGpuDialog = true
					scanner.lastAction = os.clock()
				end)
				return false
			else
				scanner.active = false
				bot.isScanning = false
				bot.scanHouse = 1
				msg("Синхронизация завершена")
				return false
			end
		end

		if bot.enabled then
			lua_thread.create(function()
				wait(400)
				local dialogIndex = bot.house - 1
				sampSendDialogResponse(id, 1, dialogIndex, "")
			end)
			return false
		end
		
		if btcCollector.active then
			lua_thread.create(function()
				wait(collectDelay[0])
				sampSendDialogResponse(id, 1, btcCollector.house - 1, "")
			end)
			return false
		end
		
		if globalBtcCollector.active then
			btcCollector.active = true
			btcCollector.house = globalBtcCollector.house
			btcCollector.gpu = 1

			lua_thread.create(function()
				wait(collectDelay[0])
				sampSendDialogResponse(id, 1, globalBtcCollector.house - 1, "")
			end)
			return false
		end
		
		if gpuStarter.active then
			lua_thread.create(function()
				wait(200)
				sampSendDialogResponse(id, 1, gpuStarter.house - 1, "")
			end)
			return false
		end

		if singleHouseRefresh.active then
			manualOpen.active = false

			lua_thread.create(function()
				wait(400)
				sampSendDialogResponse(id, 1, singleHouseRefresh.house - 1, "")
			end)
			return false
		end
		
		manualOpen.active = true

		lua_thread.create(function()
			wait(300)
			sampSendDialogResponse(id, 0, 0, "")
			wait(600)
			openAuraUiWithMonitoring()
		end)

		return false
	end

    -- ===== СПИСОК ВИДЕОКАРТ =====
	if cleanTitle:find("Выберите видеокарту") then
		local targetHouse

		if scanner.active then
			targetHouse = scanner.house
		elseif bot.enabled then
			targetHouse = bot.house
		elseif singleHouseRefresh.active then
			targetHouse = singleHouseRefresh.house
		elseif manualOpen.active then
			targetHouse = 1
		else
			targetHouse = selectedHouseTab
		end

		local cardIdx = 1

		for line in text:gmatch("[^\r\n]+") do
			if line:find("^Полка") then
				local cleanLine = line:gsub("\t", " "):gsub("%s+", " ")

				local isWorking = cleanLine:find("Работает") ~= nil
				local btcValue = cleanLine:match("(%d+%.%d+)") or "0.000000"
				local btcValueNum = tonumber(btcValue) or 0
				local btcWhole = math.floor(btcValueNum)


				local cardLvl = cleanLine:match("(%d+)%s+уровень") or "0"
				local cardTemp = cleanLine:match("(%d+%.%d+)%%") or "0"

				if globalBtcCollector.active and btcValueNum > 0 then
					btcStats.collected = btcStats.collected + btcValueNum
				end
				local cardLvl = cleanLine:match("(%d+)%s+уровень") or "0"
				local cardTemp = cleanLine:match("(%d+%.%d+)%%") or "0"

				if gpu_data[targetHouse] and gpu_data[targetHouse][cardIdx] then
					gpu_data[targetHouse][cardIdx] = {
						status = isWorking and u8"Работает" or u8"На паузе",
						btc = btcValue,
						level = cardLvl,
						temp = cardTemp
					}
				end

				cardIdx = cardIdx + 1
			end
		end

		if scanner.active then
			selectedHouseTab = scanner.house
			bot.scanHouse = scanner.house

			lua_thread.create(function()
				wait(400)
				sampSendDialogResponse(id, 0, 0, "")
				wait(1000)

				scanner.house = scanner.house + 1
				scanner.waitingHouseDialog = true
				scanner.waitingGpuDialog = false
				scanner.lastAction = os.clock()
			end)

			return false
		end

		if bot.enabled and bot.mode == "one_house" then
			selectedHouseTab = bot.house

			lua_thread.create(function()
				wait(300)
				if bot.gpu <= maxGpu then
					sampSendDialogResponse(id, 1, bot.gpu - 1, "")
				else
					stopBot("Дом #" .. bot.house .. " обработан")
				end
			end)

			return false
		end
		
		if btcCollector.active then
			selectedHouseTab = btcCollector.house

			local targetListboxId = nil
			local listboxId = -1

			for line in text:gmatch("[^\r\n]+") do
				if line:find("^Полка") then
					local amount = tonumber(line:match("([%d%.]+)%s*BTC")) or 0
					if amount >= 1 and targetListboxId == nil then
						targetListboxId = listboxId
					end
				end
				listboxId = listboxId + 1
			end

			lua_thread.create(function()
				wait(300)

				if targetListboxId ~= nil then
					sampSendDialogResponse(id, 1, targetListboxId, "")
				else
					btcCollector.active = false
					btcCollector.gpu = 1

					if globalBtcCollector.active then
						-- СНАЧАЛА ДОБАВЛЯЕМ ИТОГ ТЕКУЩЕГО ДОМА В ОБЩУЮ СТАТИСТИКУ
						btcStats.collected = btcStats.collected + singleBtcStats.collected
						singleBtcStats.collected = 0

						globalBtcCollector.house = globalBtcCollector.house + 1

						if globalBtcCollector.house <= maxHouses then
							btcCollector.active = true
							btcCollector.house = globalBtcCollector.house
							btcCollector.gpu = 1

							wait(700)
							sampProcessChatInput("/flashminer")
						else
							globalBtcCollector.active = false
							globalBtcCollector.house = 1

							local totalBTC = btcStats.collected
							local totalMoney = math.floor(totalBTC * btcRate)

							msg(string.format(
								"{FFFFFF}[AURA] Глобальный сбор завершен | {FFD700}BTC: %d {FFFFFF}| По курсу: {00FF66}%s${FFFFFF}",
								totalBTC,
								formatNumberDots(totalMoney)
							))

							btcStats.collected = 0
							singleBtcStats.collected = 0
						end
					else
						local totalBTC = singleBtcStats.collected
						local totalMoney = math.floor(totalBTC * btcRate)

						msg(string.format(
							"{FFFFFF}[AURA] Дом #%d обработан | {FFD700}BTC: %d {FFFFFF}| По курсу: {00FF66}%s${FFFFFF}",
							btcCollector.house,
							totalBTC,
							formatNumberDots(totalMoney)
						))

						singleBtcStats.collected = 0
					end
				end
			end)

			return false
		end
		
		if gpuStarter.active then
			selectedHouseTab = gpuStarter.house

			local targetListboxId = nil
			local listboxId = -1

			for line in text:gmatch("[^\r\n]+") do
				if line:find("^Полка") then
					local isPaused = line:find("На паузе") ~= nil
					local coolant = tonumber(line:match("([%d%.]+)%%")) or 0

					if isPaused and coolant > 0 and targetListboxId == nil then
						targetListboxId = listboxId
					end
				end
				listboxId = listboxId + 1
			end

			lua_thread.create(function()
				wait(300)

				if targetListboxId ~= nil then
					sampSendDialogResponse(id, 1, targetListboxId, "")
				else
					gpuStarter.active = false
				end
			end)

			return false
		end
		
		if singleHouseRefresh.active then
			selectedHouseTab = singleHouseRefresh.house

			lua_thread.create(function()
				wait(300)
				sampSendDialogResponse(id, 0, 0, "")
			end)

			singleHouseRefresh.active = false
			manualOpen.active = false
			return false
		end
		
		if manualOpen.active then
			selectedHouseTab = 1

			lua_thread.create(function()
				wait(200)
				sampSendDialogResponse(id, 0, 0, "")
			end)

			manualOpen.active = false
			return false
		end

		return
	end
	
	-- ===== ПОДТВЕРЖДЕНИЕ ВЫВОДА ПРИБЫЛИ =====
	if btcCollector.active and cleanTitle:find("Вывод прибыли видеокарты") then
		lua_thread.create(function()
			wait(250)
			sampSendDialogResponse(id, 1, 0, "") -- "Вывод"
		end)

		return false
	end

    -- ===== МЕНЮ ОДНОЙ ВИДЕОКАРТЫ =====
    if cleanTitle:find("Стойка") or text:find("видеокарту") then
		
		if btcCollector.active then
			lua_thread.create(function()
				wait(250)

				local btnIdx = nil
				local lineIndex = 0
				local canWithdraw = false

				for line in text:gmatch("[^\r\n]+") do
					local cleanLine = line:gsub("{......}", "")

					if cleanLine:find("Забрать прибыль") then
						local amount = cleanLine:match("%(([%d%.]+)%s*BTC%)")
						amount = tonumber(amount or "0")

						if amount and amount >= 1 then
							btnIdx = lineIndex
							canWithdraw = true
						end
						break
					end

					lineIndex = lineIndex + 1
				end

				if canWithdraw and btnIdx ~= nil then
					sampSendDialogResponse(id, 1, btnIdx, "")
				else
					sampSendDialogResponse(id, 0, 0, "") -- назад к списку
				end
			end)

			return false
		end
		
		if gpuStarter.active then
			lua_thread.create(function()
				wait(250)

				local btnIdx = nil
				local lineIndex = 0

				for line in text:gmatch("[^\r\n]+") do
					local cleanLine = line:gsub("{......}", "")

					if cleanLine:find("Запустить видеокарту") then
						btnIdx = lineIndex
						break
					end

					lineIndex = lineIndex + 1
				end

				if btnIdx ~= nil then
					sampSendDialogResponse(id, 1, btnIdx, "")
				else
					sampSendDialogResponse(id, 0, 0, "")
				end
			end)

			return false
		end
		
        if bot.enabled and bot.mode == "one_house" then
            lua_thread.create(function()
                wait(250)

                if text:find("Снять биткоины") then
                    local btnIdx = 0
                    if text:find("Улучшить") then
                        btnIdx = 1
                    end
                    sampSendDialogResponse(id, 1, btnIdx, "")
                else
                    sampSendDialogResponse(id, 0, 0, "")
                end

                wait(collectDelay[0])
                bot.gpu = bot.gpu + 1

                if bot.gpu <= maxGpu then
                    sampProcessChatInput("/flashminer")
                else
                    stopBot("Дом #" .. bot.house .. " обработан")
                end
            end)

            return false
        end
    end
end




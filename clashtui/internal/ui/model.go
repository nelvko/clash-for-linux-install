package ui

import (
	"fmt"
	"net/url"
	"sort"
	"strings"

	"github.com/charmbracelet/bubbles/list"
	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"

	"github.com/nelvko/clash-for-linux-install/clashtui/internal/clash"
)

type Opts struct {
	Client     *clash.Client
	Controller string
}

type model struct {
	client     *clash.Client
	controller string
	mode       string

	panel    panel
	groups   list.Model
	proxies  list.Model
	groupNow map[string]string
	groupAll map[string][]string
	modes    list.Model

	proxyDelay map[string]int
	testing    bool

	errMsg    string
	statusMsg string
}

type panel int

const (
	panelGroups panel = iota
	panelProxies
	panelMode
)

type item struct {
	title string
	desc  string
	value string
}

func (i item) Title() string       { return i.title }
func (i item) Description() string { return i.desc }
func (i item) FilterValue() string { return i.value }

func New(opts Opts) tea.Model {
	dg := list.NewDefaultDelegate()
	dg.ShowDescription = true
	dg.SetHeight(2)

	g := list.New(nil, dg, 0, 0)
	g.Title = "Groups"
	g.SetShowHelp(false)

	p := list.New(nil, dg, 0, 0)
	p.Title = "Proxies"
	p.SetShowHelp(false)

	modeList := list.New(nil, dg, 0, 0)
	modeList.Title = "Mode"
	modeList.SetShowHelp(false)
	modeList.SetItems([]list.Item{
		item{title: "Rule", desc: "", value: "Rule"},
		item{title: "Global", desc: "", value: "Global"},
		item{title: "Direct", desc: "", value: "Direct"},
	})

	return model{
		client:     opts.Client,
		controller: opts.Controller,
		mode:       "",
		panel:      panelGroups,
		groups:     g,
		proxies:    p,
		groupNow:   map[string]string{},
		groupAll:   map[string][]string{},
		modes:      modeList,
		proxyDelay: map[string]int{},
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(m.refreshCmd(), m.fetchModeCmd())
}

type refreshedMsg struct {
	groups   []item
	nowByGrp map[string]string
	allByGrp map[string][]string
}

type refreshErrMsg struct{ err error }

type modeMsg struct{ mode string }
type modeErrMsg struct{ err error }

type delayBatchMsg struct {
	delays map[string]int
}

type delayErrMsg struct{ err error }

func (m model) refreshCmd() tea.Cmd {
	return func() tea.Msg {
		resp, err := m.client.GetProxies()
		if err != nil {
			return refreshErrMsg{err: err}
		}
		// Groups are proxies that have an "all" list.
		var groupNames []string
		nowByGrp := map[string]string{}
		allByGrp := map[string][]string{}
		for name, p := range resp.Proxies {
			if len(p.All) == 0 {
				continue
			}
			groupNames = append(groupNames, name)
			nowByGrp[name] = p.Now
			allByGrp[name] = append([]string(nil), p.All...)
		}
		sort.Strings(groupNames)

		groups := make([]item, 0, len(groupNames))
		for _, name := range groupNames {
			now := nowByGrp[name]
			groups = append(groups, item{
				title: name,
				desc:  fmt.Sprintf("now: %s", now),
				value: name,
			})
		}
		return refreshedMsg{groups: groups, nowByGrp: nowByGrp, allByGrp: allByGrp}
	}
}

func (m model) fetchModeCmd() tea.Cmd {
	return func() tea.Msg {
		cfg, err := m.client.GetConfig()
		if err != nil {
			return modeErrMsg{err: err}
		}
		return modeMsg{mode: cfg.Mode}
	}
}

func (m model) setModeCmd(mode string) tea.Cmd {
	return func() tea.Msg {
		if err := m.client.SetMode(mode); err != nil {
			return modeErrMsg{err: err}
		}
		return modeMsg{mode: mode}
	}
}

func (m model) testAllDelayCmd() tea.Cmd {
	gi, ok := m.groups.SelectedItem().(item)
	if !ok {
		return nil
	}
	group := gi.value
	all := append([]string(nil), m.groupAll[group]...)
	// Dedup.
	seen := map[string]bool{}
	proxies := make([]string, 0, len(all))
	for _, n := range all {
		n = strings.TrimSpace(n)
		if n == "" || seen[n] {
			continue
		}
		seen[n] = true
		proxies = append(proxies, n)
	}
	if len(proxies) == 0 {
		return nil
	}

	return func() tea.Msg {
		delays := map[string]int{}
		// Use a lightweight connectivity endpoint. Many controllers accept any URL.
		testURL := "https://www.gstatic.com/generate_204"
		timeoutMS := 5000
		for _, name := range proxies {
			resp, err := m.client.GetProxyDelay(name, testURL, timeoutMS)
			if err != nil {
				delays[name] = -1
				continue
			}
			delays[name] = resp.Delay
		}
		return delayBatchMsg{delays: delays}
	}
}

func (m model) testSelectedDelayCmd() tea.Cmd {
	pi, ok := m.proxies.SelectedItem().(item)
	if !ok {
		return nil
	}
	name := strings.TrimSpace(pi.value)
	if name == "" {
		return nil
	}
	return func() tea.Msg {
		testURL := "https://www.gstatic.com/generate_204"
		timeoutMS := 5000
		resp, err := m.client.GetProxyDelay(name, testURL, timeoutMS)
		if err != nil {
			return delayBatchMsg{delays: map[string]int{name: -1}}
		}
		return delayBatchMsg{delays: map[string]int{name: resp.Delay}}
	}
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		// two panes + padding.
		w := msg.Width
		h := msg.Height
		paneW := (w - 3) / 2
		contentH := h - 2 // top bar + bottom bar
		m.groups.SetSize(paneW, contentH)
		m.proxies.SetSize(paneW, contentH)
		m.modes.SetSize(paneW, contentH)
		return m, nil

	case refreshedMsg:
		m.errMsg = ""
		m.statusMsg = ""
		m.groupNow = msg.nowByGrp
		m.groupAll = msg.allByGrp
		items := make([]list.Item, 0, len(msg.groups))
		for _, it := range msg.groups {
			items = append(items, it)
		}
		m.groups.SetItems(items)
		m.setProxiesForSelectedGroup()
		return m, nil

	case refreshErrMsg:
		m.errMsg = msg.err.Error()
		return m, nil

	case modeMsg:
		m.mode = msg.mode
		m.errMsg = ""
		return m, nil

	case modeErrMsg:
		m.errMsg = msg.err.Error()
		return m, nil

	case delayBatchMsg:
		for k, v := range msg.delays {
			m.proxyDelay[k] = v
		}
		m.testing = false
		m.errMsg = ""
		m.setProxiesForSelectedGroup()
		return m, nil

	case delayErrMsg:
		m.testing = false
		m.errMsg = msg.err.Error()
		return m, nil

	case selectedMsg:
		if msg.ok {
			m.statusMsg = fmt.Sprintf("selected %s -> %s", msg.group, msg.name)
			return m, m.refreshCmd()
		}
		return m, nil

	case selectErrMsg:
		m.errMsg = msg.err.Error()
		return m, nil

	case tea.KeyMsg:
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit
		case "1":
			m.panel = panelGroups
			return m, nil
		case "2":
			m.panel = panelProxies
			return m, nil
		case "3":
			m.panel = panelMode
			return m, nil
		case "tab":
			m.panel = (m.panel + 1) % 3
			return m, nil
		case "r":
			return m, tea.Batch(m.refreshCmd(), m.fetchModeCmd())
		case "t":
			if m.panel == panelProxies && !m.testing {
				m.testing = true
				m.statusMsg = "testing selected..."
				return m, m.testSelectedDelayCmd()
			}
			return m, nil
		case "T":
			if m.panel == panelProxies && !m.testing {
				m.testing = true
				m.statusMsg = "testing all..."
				return m, m.testAllDelayCmd()
			}
			return m, nil
		case "esc":
			if m.panel == panelMode {
				m.panel = panelProxies
				return m, nil
			}
			return m, nil
		case "enter":
			switch m.panel {
			case panelGroups:
				m.panel = panelProxies
				return m, nil
			case panelProxies:
				return m, m.selectCurrentProxyCmd()
			case panelMode:
				it, ok := m.modes.SelectedItem().(item)
				if !ok {
					m.panel = panelProxies
					return m, nil
				}
				return m, tea.Batch(m.setModeCmd(it.value), m.fetchModeCmd())
			}
		}
	}

	var cmd tea.Cmd
	switch m.panel {
	case panelGroups:
		m.groups, cmd = m.groups.Update(msg)
		m.setProxiesForSelectedGroup()
	case panelProxies:
		m.proxies, cmd = m.proxies.Update(msg)
	case panelMode:
		m.modes, cmd = m.modes.Update(msg)
	}
	return m, cmd
}

func (m *model) setProxiesForSelectedGroup() {
	gi, ok := m.groups.SelectedItem().(item)
	if !ok {
		m.proxies.SetItems(nil)
		m.proxies.Title = "Proxies"
		return
	}
	group := gi.value
	all := m.groupAll[group]
	now := m.groupNow[group]

	items := make([]list.Item, 0, len(all))
	for _, name := range all {
		desc := "delay: -"
		if d, ok := m.proxyDelay[name]; ok {
			if d >= 0 {
				desc = fmt.Sprintf("delay: %dms", d)
			}
		}

		prefix := "  "
		if name == now {
			prefix = "* "
		}
		items = append(items, item{title: prefix + name, desc: desc, value: name})
	}
	m.proxies.SetItems(items)
	m.proxies.Title = fmt.Sprintf("Proxies (%s)", group)
}

type selectedMsg struct {
	ok    bool
	group string
	name  string
}
type selectErrMsg struct{ err error }

func (m model) selectCurrentProxyCmd() tea.Cmd {
	return func() tea.Msg {
		gi, ok := m.groups.SelectedItem().(item)
		if !ok {
			return selectedMsg{ok: false}
		}
		pi, ok := m.proxies.SelectedItem().(item)
		if !ok {
			return selectedMsg{ok: false}
		}
		group := gi.value
		name := strings.TrimSpace(pi.value)
		if err := m.client.SelectProxy(group, name); err != nil {
			return selectErrMsg{err: err}
		}
		return selectedMsg{ok: true, group: group, name: name}
	}
}

func (m model) View() string {
	mode := m.mode
	if mode == "" {
		mode = "?"
	}
	controllerHost := m.controller
	if u, err := url.Parse(m.controller); err == nil {
		controllerHost = u.Host
	}

	activeTab := lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("0")).Background(lipgloss.Color("6")).Padding(0, 1)
	inactiveTab := lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Padding(0, 1)
	leftInfo := lipgloss.NewStyle().Bold(true).Render("clashtui")
	rightInfo := lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Render(fmt.Sprintf("controller: %s  mode: %s", controllerHost, mode))

	tabs := []struct {
		p    panel
		text string
	}{
		{panelGroups, "1 Groups"},
		{panelProxies, "2 Proxies"},
		{panelMode, "3 Mode"},
	}
	var tabParts []string
	for _, t := range tabs {
		if m.panel == t.p {
			tabParts = append(tabParts, activeTab.Render(t.text))
		} else {
			tabParts = append(tabParts, inactiveTab.Render(t.text))
		}
	}
	tabBar := lipgloss.JoinHorizontal(lipgloss.Top, tabParts...)
	// Top bar: title + tabs + right info.
	top := lipgloss.NewStyle().Padding(0, 1).Render(lipgloss.JoinHorizontal(lipgloss.Top, leftInfo, "  ", tabBar, "  ", rightInfo))

	status := m.statusMsg
	if m.testing {
		status = "testing..."
	}
	if m.errMsg != "" {
		status = "error: " + m.errMsg
	}

	paneStyle := lipgloss.NewStyle().Border(lipgloss.RoundedBorder()).Padding(0, 1)
	activePaneStyle := paneStyle.Copy().BorderForeground(lipgloss.Color("6"))

	leftStyle := paneStyle
	rightStyle := paneStyle
	if m.panel == panelGroups {
		leftStyle = activePaneStyle
	}
	if m.panel == panelProxies {
		rightStyle = activePaneStyle
	}

	left := leftStyle.Render(m.groups.View())
	right := rightStyle.Render(m.proxies.View())

	content := lipgloss.JoinHorizontal(lipgloss.Top, left, " ", right)
	if m.panel == panelMode {
		// Mode behaves like a panel but is rendered as a centered overlay.
		overlay := activePaneStyle.Render(m.modes.View())
		content = content + "\n\n" + overlay
	}

	helpCommon := "1/2/3: panel  tab: next  r: refresh  q: quit"
	help := helpCommon
	switch m.panel {
	case panelGroups:
		help = helpCommon + "  enter: focus proxies"
	case panelProxies:
		help = helpCommon + "  enter: select  t: test  T: test all"
	case panelMode:
		help = helpCommon + "  up/down: choose  enter: apply  esc: close"
	}
	bottom := lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Padding(0, 1).Render(help)
	if status != "" {
		bottom = lipgloss.NewStyle().Foreground(lipgloss.Color("7")).Padding(0, 1).Render(help + "  |  " + status)
	}

	return top + "\n" + content + "\n" + bottom
}

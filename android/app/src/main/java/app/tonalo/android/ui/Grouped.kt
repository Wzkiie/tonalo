package app.tonalo.android.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForwardIos
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.UnfoldMore
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp

/*
 * The iPhone's grouped lists: rows in a rounded card, a thin line between them, a gray header above and a
 * small note below. Used by the settings and every page that is mostly switches and choices.
 */

private val GroupShape = RoundedCornerShape(22.dp)

/** A page with the round back button, the title in the middle and grouped content below. */
@Composable
fun GroupedPage(title: String, actions: @Composable () -> Unit = {}, content: LazyListScope.() -> Unit) {
    Column(Modifier.fillMaxSize()) {
        TopBar(title, actions = actions)
        LazyColumn(
            Modifier.fillMaxSize(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 32.dp),
            content = content,
        )
    }
}

/**
 * One rounded card of rows. Lines between the rows are drawn here, so a row that's left out (an `if`)
 * leaves no double line behind.
 */
@Composable
fun Group(header: String? = null, footer: String? = null, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(modifier.fillMaxWidth().padding(bottom = 22.dp)) {
        if (header != null) Text(
            header, Modifier.padding(start = 16.dp, bottom = 8.dp),
            color = Palette.secondaryText, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
        )
        val tops = remember { IntArrayHolder() }
        val line = Color.White.copy(alpha = 0.1f)
        Layout(
            content,
            Modifier.fillMaxWidth().clip(GroupShape).background(Palette.card).drawWithContent {
                drawContent()
                val inset = 16.dp.toPx()
                tops.values.drop(1).forEach { y ->
                    drawLine(line, Offset(inset, y.toFloat()), Offset(size.width - inset, y.toFloat()), strokeWidth = 1f)
                }
            },
        ) { measurables, constraints ->
            val placeables = measurables.map { it.measure(constraints.copy(minHeight = 0)) }.filter { it.height > 0 }
            tops.values = placeables.runningFold(0) { y, p -> y + p.height }.dropLast(1)
            layout(constraints.maxWidth, placeables.sumOf { it.height }) {
                var y = 0
                placeables.forEach { it.place(0, y); y += it.height }
            }
        }
        if (footer != null) Text(
            footer, Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
            color = Palette.secondaryText, style = MaterialTheme.typography.bodySmall,
        )
    }
}

private class IntArrayHolder { var values: List<Int> = emptyList() }

/** The frame every row shares: the height, the padding, an optional icon in front. */
@Composable
fun GroupRow(
    onClick: (() -> Unit)? = null,
    icon: (@Composable () -> Unit)? = null,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 54.dp)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(horizontal = 16.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) { icon(); Spacer(Modifier.width(14.dp)) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.Center, content = content)
        if (trailing != null) { Spacer(Modifier.width(8.dp)); trailing() }
    }
}

@Composable
private fun RowTitle(title: String, sub: String?, color: Color = Color.White) {
    Text(title, color = color, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
    if (!sub.isNullOrEmpty()) Text(sub, color = Palette.secondaryText, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 2.dp))
}

@Composable
private fun RowValue(value: String?) {
    if (!value.isNullOrEmpty()) Text(
        value, Modifier.padding(start = 8.dp), color = Palette.secondaryText, style = MaterialTheme.typography.bodyLarge,
        maxLines = 1, overflow = TextOverflow.Ellipsis, textAlign = TextAlign.End,
    )
}

/** Opens another page: title, the current value in gray, a chevron. */
@Composable
fun NavRow(title: String, value: String? = null, sub: String? = null, icon: (@Composable () -> Unit)? = null, onClick: () -> Unit) {
    GroupRow(onClick, icon, trailing = {
        Row(Modifier.widthIn(max = 200.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f, fill = false)) { RowValue(value) }
            Icon(Icons.AutoMirrored.Filled.ArrowForwardIos, null, tint = Palette.subtle, modifier = Modifier.padding(start = 8.dp).size(14.dp))
        }
    }) { RowTitle(title, sub) }
}

/** A fixed value, nothing to tap. */
@Composable
fun ValueRow(title: String, value: String?) {
    GroupRow(trailing = { RowValue(value) }) { RowTitle(title, null) }
}

/** Opens a web page outside the app. */
@Composable
fun LinkRow(title: String, onClick: () -> Unit) {
    GroupRow(onClick, trailing = { Icon(Icons.AutoMirrored.Filled.OpenInNew, null, tint = Palette.accent, modifier = Modifier.size(20.dp)) }) {
        RowTitle(title, null)
    }
}

@Composable
fun ToggleRow(title: String, checked: Boolean, sub: String? = null, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    GroupRow(if (enabled) ({ onChange(!checked) }) else null, trailing = {
        Switch(
            checked, onChange, enabled = enabled,
            colors = SwitchDefaults.colors(
                checkedTrackColor = Palette.accent, checkedThumbColor = Color.White,
                uncheckedTrackColor = Palette.elevated, uncheckedBorderColor = Color.Transparent, uncheckedThumbColor = Palette.secondaryText,
            ),
        )
    }) { RowTitle(title, sub) }
}

/** Picks one of a few values from a menu at the row. */
@Composable
fun <T> PickerRow(title: String, value: T, options: List<T>, sub: String? = null, label: @Composable (T) -> String, onPick: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        GroupRow({ open = true }, trailing = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                RowValue(label(value))
                Icon(Icons.Default.UnfoldMore, null, tint = Palette.subtle, modifier = Modifier.padding(start = 4.dp).size(18.dp))
            }
        }) { RowTitle(title, sub) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }, modifier = Modifier.background(Palette.elevated)) {
            options.forEach { o ->
                DropdownMenuItem(
                    text = { Text(label(o)) },
                    leadingIcon = { if (o == value) Icon(Icons.Default.Check, null, tint = Palette.accent) else Spacer(Modifier.size(24.dp)) },
                    onClick = { onPick(o); open = false },
                )
            }
        }
    }
}

/** One of several choices, all visible: a check at the chosen one. */
@Composable
fun CheckRow(title: String, checked: Boolean, sub: String? = null, onClick: () -> Unit) {
    GroupRow(onClick, trailing = { if (checked) Icon(Icons.Default.Check, null, tint = Palette.accent) }) { RowTitle(title, sub) }
}

/** A button in the accent color (or red), like "Add another account". */
@Composable
fun ActionRow(title: String, icon: ImageVector? = null, destructive: Boolean = false, centered: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val color = when {
        !enabled -> Palette.subtle
        destructive -> Color(0xFFFF5A5F)
        else -> Palette.accent
    }
    GroupRow(if (enabled) onClick else null, icon = icon?.let { { Icon(it, null, tint = color, modifier = Modifier.size(24.dp)) } }) {
        Text(
            title, color = color, style = MaterialTheme.typography.bodyLarge,
            modifier = if (centered) Modifier.fillMaxWidth() else Modifier, textAlign = if (centered) TextAlign.Center else TextAlign.Start,
        )
    }
}

/** A text field inside a group row, without the Material frame. */
@Composable
fun FieldRow(
    value: String,
    onChange: (String) -> Unit,
    placeholder: String,
    title: String? = null,
    password: Boolean = false,
    keyboard: KeyboardOptions = KeyboardOptions.Default,
) {
    GroupRow {
        if (title != null) Text(title, color = Palette.secondaryText, style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(bottom = 4.dp))
        Box {
            if (value.isEmpty()) Text(placeholder, color = Palette.subtle, style = MaterialTheme.typography.bodyLarge)
            BasicTextField(
                value, onChange, Modifier.fillMaxWidth(), singleLine = true,
                textStyle = MaterialTheme.typography.bodyLarge.copy(color = Color.White),
                cursorBrush = SolidColor(Palette.accent),
                visualTransformation = if (password) PasswordVisualTransformation() else VisualTransformation.None,
                keyboardOptions = keyboard,
            )
        }
    }
}

/** Free content in a group (a row of color dots, a slider). */
@Composable
fun GroupBox(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(16.dp), content = content)
}

/** The bottom of a page that has no tabs: room for the gesture bar. */
@Composable
fun BottomSpace() = Spacer(Modifier.navigationBarsPadding().padding(bottom = 8.dp))

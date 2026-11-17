import { AppError } from './errors.mjs';
import diskTypes from '../pan-types.json' with { type: 'json' };

export const panSearchDefaults = { panCloudTypes: '', panChannels: '', panPlugins: '', panInclude: '', panExclude: '', panSource: 'all', panResult: 'merge', panConcurrency: '', panRefresh: false, panExt: '', panCheckLinks: true };

function list(value, label, phrases = false) {
  if (value == null) return [];
  if (typeof value !== 'string' || value.length > 2048) throw new AppError('INVALID_ARGUMENT', `${label}无效`);
  return [...new Set(value.split(phrases ? /[,，;；\r\n]+/ : /[,，;；\s]+/).map(item => item.trim()).filter(Boolean))];
}

export function normalizePanOptions(config) {
  const result = {};
  for (const [key, label] of Object.entries({ panCloudTypes: '网盘类型', panChannels: 'TG 频道', panPlugins: '插件', panInclude: '包含关键词', panExclude: '排除关键词' })) {
    const values = list(config[key], label, key === 'panInclude' || key === 'panExclude');
    if (values.length > 100) throw new AppError('INVALID_ARGUMENT', `${label}最多填写 100 项`);
    if (['panChannels', 'panPlugins'].includes(key) && values.includes('0') && values.length !== 1)
      throw new AppError('INVALID_ARGUMENT', `${label}中的 0 必须单独填写，不能与名称混用`);
    if (key === 'panCloudTypes' && values.some(value => !Object.hasOwn(diskTypes, value)))
      throw new AppError('INVALID_ARGUMENT', '网盘类型无效，请从支持的网盘中选择');
    result[key] = values.join(',');
  }
  result.panSource = config.panSource ?? 'all';
  result.panResult = config.panResult ?? 'merge';
  if (!['all', 'tg', 'plugin'].includes(result.panSource) || !['merge', 'all', 'results'].includes(result.panResult))
    throw new AppError('INVALID_ARGUMENT', '盘搜来源或结果类型无效');
  result.panConcurrency = config.panConcurrency ?? '';
  if (result.panConcurrency !== '' && (!/^\d+$/.test(result.panConcurrency) || +result.panConcurrency < 1 || +result.panConcurrency > 64))
    throw new AppError('INVALID_ARGUMENT', '盘搜并发数应为 1 至 64 的整数，留空为自动');
  result.panRefresh = config.panRefresh === true;
  result.panCheckLinks = config.panCheckLinks !== false;
  result.panExt = config.panExt ?? '';
  if (result.panExt) {
    let value;
    try { value = JSON.parse(result.panExt); } catch { throw new AppError('INVALID_ARGUMENT', '插件扩展参数需要有效 JSON 对象'); }
    if (!value || typeof value !== 'object' || Array.isArray(value)) throw new AppError('INVALID_ARGUMENT', '插件扩展参数需要 JSON 对象');
    result.panExt = JSON.stringify(value);
  }
  return result;
}

export function panSearchRequest(query, config) {
  const options = normalizePanOptions(config);
  const tgOff = options.panChannels === '0', pluginsOff = options.panPlugins === '0';
  if (tgOff && pluginsOff) throw new AppError('INVALID_ARGUMENT', 'TG 频道和插件均已关闭，请在盘搜设置中启用至少一种来源');
  const src = options.panSource === 'all' ? (tgOff ? 'plugin' : pluginsOff ? 'tg' : 'all') : options.panSource;
  if (src === 'tg' && tgOff || src === 'plugin' && pluginsOff) throw new AppError('INVALID_ARGUMENT', '选中的盘搜来源已关闭');
  const request = { kw: query, res: options.panResult, src };
  if (options.panConcurrency) request.conc = Number(options.panConcurrency);
  if (options.panRefresh) request.refresh = true;
  if (options.panExt) request.ext = JSON.parse(options.panExt);
  for (const [key, target] of [['panCloudTypes', 'cloud_types'], ['panChannels', 'channels'], ['panPlugins', 'plugins']])
    if (options[key] && options[key] !== '0') request[target] = options[key].split(',');
  const filter = {};
  if (options.panInclude) filter.include = options.panInclude.split(',');
  if (options.panExclude) filter.exclude = options.panExclude.split(',');
  if (Object.keys(filter).length) request.filter = filter;
  return request;
}

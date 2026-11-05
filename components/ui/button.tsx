import * as React from 'react';
import {Slot} from '@radix-ui/react-slot';
import {cva,type VariantProps} from 'class-variance-authority';
import {clsx} from 'clsx';import {twMerge} from 'tailwind-merge';
const variants=cva('inline-flex items-center justify-center gap-2 rounded-xl min-h-11 px-4 py-2 font-semibold transition-colors disabled:opacity-50',{variants:{variant:{default:'bg-indigo-600 text-white hover:bg-indigo-700',outline:'border border-slate-300 bg-transparent text-inherit'}},defaultVariants:{variant:'default'}});
export function Button({className,variant,asChild=false,...props}:React.ComponentProps<'button'>&VariantProps<typeof variants>&{asChild?:boolean}){const Comp=asChild?Slot:'button';return <Comp className={twMerge(clsx(variants({variant}),className))} {...props}/>}
